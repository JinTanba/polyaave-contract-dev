// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./Base.t.sol";
import {Pool} from "../src/Pool.sol";
import {AaveModule} from "../src/adaptor/AaveModule.sol";
import {RiskParams, PoolData, MarketData, UserPosition, DataType} from "../src/libraries/DataStruct.sol";
import {StorageShell} from "../src/libraries/StorageShell.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILiquidityLayer} from "../src/interfaces/ILiquidityLayer.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import "./mocks/MockOracle.sol";
import "./mocks/MockPredictionToken.sol";

contract BorrowRepayTest is PolynanceTest {
    using WadRayMath for uint256;
    
    Pool public pool;
    AaveModule public aaveModule;
    MockOracle public mockOracle;
    MockPredictionToken public predictionToken;
    
    address public curator;
    address public supplier;
    address public borrower;
    
    uint256 constant PREDICTION_TOKEN_PRICE = 5e17; // 0.5 in Wad (50 cents)
    uint256 constant PREDICTION_TOKEN_DECIMALS = 6;
    uint256 constant INITIAL_SUPPLY = 100000 * 10 ** 6; // 100,000 USDC
    
    function setUp() public override {
        super.setUp();
        
        // Setup test accounts
        curator = makeAddr("curator");
        supplier = makeAddr("supplier");
        borrower = makeAddr("borrower");
        
        // Deploy mock oracle and prediction token
        mockOracle = new MockOracle();
        predictionToken = new MockPredictionToken("Prediction Token", "PRED", uint8(PREDICTION_TOKEN_DECIMALS));
        mockOracle.setPrice(address(predictionToken), PREDICTION_TOKEN_PRICE);
        
        // Deploy AaveModule
        address[] memory assets = new address[](1);
        assets[0] = address(USDC);
        aaveModule = new AaveModule(assets);
        
        // Setup risk parameters with mock oracle
        RiskParams memory riskParams = RiskParams({
            priceOracle: address(mockOracle),
            liquidityLayer: address(aaveModule),
            supplyAsset: address(USDC),
            curator: curator,
            baseSpreadRate: 1e25, // 0.01 in Ray (1%)
            optimalUtilization: 8e26, // 0.8 in Ray (80%)
            slope1: 5e25, // 0.05 in Ray (5%)
            slope2: 1e27, // 1.0 in Ray (100%)
            reserveFactor: 1e26, // 0.1 in Ray (10%)
            ltv: 6000, // 60%
            liquidationThreshold: 7500, // 75%
            liquidationCloseFactor: 5000, // 50%
            liquidationBonus: 1000, // 10%
            lpShareOfRedeemed: 8000, // 80%
            supplyAssetDecimals: 6
        });
        
        // Deploy pool
        vm.prank(curator);
        pool = new Pool("Polynance LP Token", "POLYLP", riskParams);
        
        // Initialize the market
        // Due to inverted logic in line 247, the function will fail if market is NOT active
        // So we just call it directly
        vm.prank(curator);
        pool.initializeMarket(address(predictionToken), PREDICTION_TOKEN_DECIMALS);
        
        // Supply liquidity to the pool
        deal(address(USDC), supplier, INITIAL_SUPPLY);
        vm.startPrank(supplier);
        USDC.approve(address(pool), INITIAL_SUPPLY);
        pool.supply(INITIAL_SUPPLY);
        vm.stopPrank();
        
        // Fund borrower with prediction tokens and some USDC for repayments
        predictionToken.mint(borrower, 10000 * 10 ** PREDICTION_TOKEN_DECIMALS);
        deal(address(USDC), borrower, 10000 * 10 ** 6);
    }
    
    // ============ Borrow Tests ============
    
    function test_Borrow_Success() public {
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS; // 1,000 tokens = $500
        uint256 borrowAmount = 200 * 10 ** 6; // 200 USDC
        
        // Get initial balances
        uint256 borrowerUsdcBefore = USDC.balanceOf(borrower);
        uint256 poolPredTokenBefore = predictionToken.balanceOf(address(pool));
        
        // Execute borrow
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateralAmount);
        
        uint256 actualBorrowAmount = pool.borrow(
            address(predictionToken),
            collateralAmount,
            borrowAmount
        );
        vm.stopPrank();
        
        // Verify balances
        assertEq(actualBorrowAmount, borrowAmount, "Should borrow requested amount");
        assertEq(USDC.balanceOf(borrower) - borrowerUsdcBefore, borrowAmount, "Borrower should receive USDC");
        assertEq(predictionToken.balanceOf(address(pool)) - poolPredTokenBefore, collateralAmount, "Pool should receive collateral");
        
        // Verify storage state
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        bytes32 positionId = StorageShell.userPositionId(marketId, borrower);
        
        MarketData memory market = StorageShell.getMarketData(marketId);
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        PoolData memory poolData = StorageShell.getPool();
        
        // Check position
        assertEq(position.collateralAmount, collateralAmount, "Position collateral incorrect");
        assertEq(position.borrowAmount, borrowAmount, "Position borrow amount incorrect");
        assertTrue(position.scaledDebtBalance > 0, "Scaled debt should be set");
        
        // Check market totals
        assertEq(market.totalBorrowed, borrowAmount, "Market total borrowed incorrect");
        assertEq(market.totalCollateral, collateralAmount, "Market total collateral incorrect");
        
        // Check pool totals
        assertEq(poolData.totalBorrowedAllMarkets, borrowAmount, "Pool total borrowed incorrect");
    }
    
    function test_Borrow_MaxLTV() public {
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS; // $500 worth
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateralAmount);
        
        // Borrow max (pass 0)
        uint256 actualBorrowAmount = pool.borrow(
            address(predictionToken),
            collateralAmount,
            0 // 0 means borrow max
        );
        vm.stopPrank();
        
        // With 60% LTV and $500 collateral, max borrow should be $300
        uint256 expectedMax = 300 * 10 ** 6;
        assertApproxEqAbs(actualBorrowAmount, expectedMax, 1e6, "Max borrow should be 60% of collateral value");
    }
    
    function test_Borrow_ExceedLTV_Reverts() public {
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS;
        uint256 borrowAmount = 400 * 10 ** 6; // $400 (80% LTV, exceeds 60%)
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateralAmount);
        
        vm.expectRevert();
        pool.borrow(address(predictionToken), collateralAmount, borrowAmount);
        vm.stopPrank();
    }
    
    // ============ Repay Tests ============
    
    function test_Repay_Full() public {
        // First, borrow
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS;
        uint256 borrowAmount = 200 * 10 ** 6;
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateralAmount);
        pool.borrow(address(predictionToken), collateralAmount, borrowAmount);
        
        // Wait for interest to accrue
        vm.warp(block.timestamp + 30 days);
        
        // Repay all (pass 0)
        USDC.approve(address(pool), type(uint256).max);
        
        uint256 collateralBefore = predictionToken.balanceOf(borrower);
        uint256 actualRepayAmount = pool.repay(address(predictionToken), 0);
        uint256 collateralAfter = predictionToken.balanceOf(borrower);
        
        vm.stopPrank();
        
        // Verify debt is cleared
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        bytes32 positionId = StorageShell.userPositionId(marketId, borrower);
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        assertEq(position.borrowAmount, 0, "Borrow amount should be 0");
        assertEq(position.scaledDebtBalance, 0, "Scaled debt should be 0");
        assertEq(position.collateralAmount, 0, "Collateral should be 0");
        
        // Verify collateral returned
        assertEq(collateralAfter - collateralBefore, collateralAmount, "All collateral should be returned");
        
        // Verify repay includes interest
        assertTrue(actualRepayAmount > borrowAmount, "Repay should include interest");
    }
    
    function test_Repay_Partial() public {
        // First, borrow
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS;
        uint256 borrowAmount = 200 * 10 ** 6;
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateralAmount);
        pool.borrow(address(predictionToken), collateralAmount, borrowAmount);
        
        // Get initial position
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        bytes32 positionId = StorageShell.userPositionId(marketId, borrower);
        UserPosition memory positionBefore = StorageShell.getUserPosition(positionId);
        
        // Repay half
        uint256 repayAmount = 100 * 10 ** 6;
        USDC.approve(address(pool), repayAmount);
        pool.repay(address(predictionToken), repayAmount);
        
        vm.stopPrank();
        
        // Verify partial repayment
        UserPosition memory positionAfter = StorageShell.getUserPosition(positionId);
        
        assertTrue(positionAfter.borrowAmount < positionBefore.borrowAmount, "Borrow amount should decrease");
        assertTrue(positionAfter.scaledDebtBalance < positionBefore.scaledDebtBalance, "Scaled debt should decrease");
        assertEq(positionAfter.collateralAmount, collateralAmount, "Collateral should remain");
    }
    
    function test_Repay_AccumulatesSpread() public {
        // Borrow and wait for significant interest
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS;
        uint256 borrowAmount = 200 * 10 ** 6;
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateralAmount);
        pool.borrow(address(predictionToken), collateralAmount, borrowAmount);
        
        // Wait a year for significant interest
        vm.warp(block.timestamp + 365 days);
        
        // Get spread before repay
        PoolData memory poolBefore = StorageShell.getPool();
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        MarketData memory marketBefore = StorageShell.getMarketData(marketId);
        
        // Repay all
        USDC.approve(address(pool), type(uint256).max);
        uint256 actualRepayAmount = pool.repay(address(predictionToken), 0);
        vm.stopPrank();
        
        // Get spread after repay
        PoolData memory poolAfter = StorageShell.getPool();
        MarketData memory marketAfter = StorageShell.getMarketData(marketId);
        
        // Verify spread accumulated
        assertTrue(poolAfter.totalAccumulatedSpread > poolBefore.totalAccumulatedSpread, "Pool spread should increase");
        assertTrue(marketAfter.accumulatedSpread > marketBefore.accumulatedSpread, "Market spread should increase");
        
        // Total repay should be significantly more than principal
        assertTrue(actualRepayAmount > borrowAmount * 101 / 100, "Should have at least 1% interest after a year");
    }
}