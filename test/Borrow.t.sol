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
import {IPoolDataProvider} from "aave-v3-core/contracts/interfaces/IPoolDataPROVIDER.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import "./mocks/MockOracle.sol";
import "./mocks/MockPredictionToken.sol";

contract BorrowTest is PolynanceTest {
    using WadRayMath for uint256;
    
    Pool public pool;
    AaveModule public aaveModule;
    MockOracle public mockOracle;
    MockPredictionToken public predictionToken;
    
    address public curator;
    address public liquidityLayer;
    address public priceOracle;
    address public supplier;
    address public borrower1;
    address public borrower2;
    
    uint256 constant INITIAL_SUPPLY = 100000 * 10 ** 6; // 100,000 USDC
    uint256 constant PREDICTION_TOKEN_PRICE = 5e17; // 0.5 in Wad (50 cents)
    uint256 constant PREDICTION_TOKEN_DECIMALS = 6;
    
    function setUp() public override {
        super.setUp();
        
        // Setup test accounts
        curator = makeAddr("curator");
        supplier = makeAddr("supplier");
        borrower1 = makeAddr("borrower1");
        borrower2 = makeAddr("borrower2");
        
        // Deploy mock oracle
        mockOracle = new MockOracle();
        priceOracle = address(mockOracle);
        
        // Deploy AaveModule with USDC
        address[] memory assets = new address[](1);
        assets[0] = address(USDC);
        aaveModule = new AaveModule(assets);
        liquidityLayer = address(aaveModule);
        
        // Setup risk parameters
        RiskParams memory riskParams = RiskParams({
            priceOracle: priceOracle,
            liquidityLayer: liquidityLayer,
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
        
        // Deploy Pool contract
        vm.prank(curator);
        pool = new Pool("Polynance LP Token", "POLYLP", riskParams);
        
        // Deploy mock prediction token
        predictionToken = new MockPredictionToken("Prediction Token", "PRED", uint8(PREDICTION_TOKEN_DECIMALS));
        
        // Set prediction token price in oracle
        mockOracle.setPrice(address(predictionToken), PREDICTION_TOKEN_PRICE);
        
        // Initialize the market
        vm.prank(curator);
        pool.initializeMarket(address(predictionToken), PREDICTION_TOKEN_DECIMALS);
        
        // Fund supplier with USDC and have them supply to pool
        deal(address(USDC), supplier, INITIAL_SUPPLY);
        vm.startPrank(supplier);
        USDC.approve(address(pool), INITIAL_SUPPLY);
        pool.supply(INITIAL_SUPPLY);
        vm.stopPrank();
        
        // Fund borrowers with prediction tokens
        predictionToken.mint(borrower1, 10000 * 10 ** PREDICTION_TOKEN_DECIMALS); // 10,000 tokens
        predictionToken.mint(borrower2, 10000 * 10 ** PREDICTION_TOKEN_DECIMALS); // 10,000 tokens
        
        // Fund borrowers with some USDC for repayments
        deal(address(USDC), borrower1, 10000 * 10 ** 6); // 10,000 USDC
        deal(address(USDC), borrower2, 10000 * 10 ** 6); // 10,000 USDC
    }
    
    // ============ Borrow Tests ============
    
    function test_Borrow_Success() public {
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS; // 1,000 prediction tokens
        uint256 borrowAmount = 200 * 10 ** 6; // 200 USDC
        
        // Get initial state
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        bytes32 positionId = StorageShell.userPositionId(marketId, borrower1);
        
        PoolData memory poolBefore = StorageShell.getPool();
        MarketData memory marketBefore = StorageShell.getMarketData(marketId);
        UserPosition memory positionBefore = StorageShell.getUserPosition(positionId);
        
        uint256 borrowerUsdcBefore = USDC.balanceOf(borrower1);
        uint256 poolPredTokenBefore = predictionToken.balanceOf(address(pool));
        
        // Borrower approves and borrows
        vm.startPrank(borrower1);
        predictionToken.approve(address(pool), collateralAmount);
        
        uint256 actualBorrowAmount = pool.borrow(
            address(predictionToken),
            collateralAmount,
            borrowAmount
        );
        vm.stopPrank();
        
        // Get final state
        PoolData memory poolAfter = StorageShell.getPool();
        MarketData memory marketAfter = StorageShell.getMarketData(marketId);
        UserPosition memory positionAfter = StorageShell.getUserPosition(positionId);
        
        uint256 borrowerUsdcAfter = USDC.balanceOf(borrower1);
        uint256 poolPredTokenAfter = predictionToken.balanceOf(address(pool));
        
        // Assertions - Basic functionality
        assertEq(actualBorrowAmount, borrowAmount, "Actual borrow amount should match requested");
        assertEq(borrowerUsdcAfter - borrowerUsdcBefore, borrowAmount, "Borrower should receive USDC");
        assertEq(poolPredTokenAfter - poolPredTokenBefore, collateralAmount, "Pool should receive collateral");
        
        // Assertions - Storage updates
        assertEq(positionAfter.collateralAmount, collateralAmount, "Position collateral should be updated");
        assertEq(positionAfter.borrowAmount, borrowAmount, "Position borrow amount should be updated");
        assertTrue(positionAfter.scaledDebtBalance > 0, "Scaled debt balance should be set");
        
        assertEq(marketAfter.totalBorrowed, borrowAmount, "Market total borrowed should increase");
        assertEq(marketAfter.totalCollateral, collateralAmount, "Market total collateral should increase");
        
        assertEq(poolAfter.totalBorrowedAllMarkets, borrowAmount, "Pool total borrowed should increase");
        assertTrue(poolAfter.totalSupplied == poolBefore.totalSupplied, "Pool total supplied should not change");
    }
    
    function test_Borrow_MultipleUsers() public {
        uint256 collateral1 = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS;
        uint256 borrow1 = 200 * 10 ** 6;
        uint256 collateral2 = 2000 * 10 ** PREDICTION_TOKEN_DECIMALS;
        uint256 borrow2 = 400 * 10 ** 6;
        
        // Borrower 1 borrows
        vm.startPrank(borrower1);
        predictionToken.approve(address(pool), collateral1);
        pool.borrow(address(predictionToken), collateral1, borrow1);
        vm.stopPrank();
        
        // Borrower 2 borrows
        vm.startPrank(borrower2);
        predictionToken.approve(address(pool), collateral2);
        pool.borrow(address(predictionToken), collateral2, borrow2);
        vm.stopPrank();
        
        // Check storage state
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        MarketData memory market = StorageShell.getMarketData(marketId);
        PoolData memory poolData = StorageShell.getPool();
        
        assertEq(market.totalBorrowed, borrow1 + borrow2, "Market total borrowed incorrect");
        assertEq(market.totalCollateral, collateral1 + collateral2, "Market total collateral incorrect");
        assertEq(poolData.totalBorrowedAllMarkets, borrow1 + borrow2, "Pool total borrowed incorrect");
        
        // Check individual positions
        bytes32 position1Id = StorageShell.userPositionId(marketId, borrower1);
        bytes32 position2Id = StorageShell.userPositionId(marketId, borrower2);
        
        UserPosition memory position1 = StorageShell.getUserPosition(position1Id);
        UserPosition memory position2 = StorageShell.getUserPosition(position2Id);
        
        assertEq(position1.borrowAmount, borrow1, "Borrower 1 borrow amount incorrect");
        assertEq(position2.borrowAmount, borrow2, "Borrower 2 borrow amount incorrect");
    }
    
    function test_Borrow_MaxLTV() public {
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS; // 1,000 tokens worth $500
        
        // With 60% LTV and $500 collateral value, max borrow should be $300 (300 USDC)
        uint256 expectedMaxBorrow = 300 * 10 ** 6;
        
        vm.startPrank(borrower1);
        predictionToken.approve(address(pool), collateralAmount);
        
        // Borrow max (passing 0 as borrowAmount)
        uint256 actualBorrowAmount = pool.borrow(
            address(predictionToken),
            collateralAmount,
            0 // 0 means borrow max
        );
        vm.stopPrank();
        
        // Allow small variance due to rounding
        assertApproxEqAbs(actualBorrowAmount, expectedMaxBorrow, 1e6, "Max borrow should be 60% of collateral value");
    }
    
    
    function test_Borrow_NoCollateral_Reverts() public {
        uint256 borrowAmount = 100 * 10 ** 6;
        
        vm.startPrank(borrower1);
        vm.expectRevert();
        pool.borrow(address(predictionToken), 0, borrowAmount);
        vm.stopPrank();
    }
    
    // ============ Repay Tests ============
    
    function test_Repay_Full_Success() public {
        // First, borrow some funds
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS;
        uint256 borrowAmount = 200 * 10 ** 6;
        
        vm.startPrank(borrower1);
        predictionToken.approve(address(pool), collateralAmount);
        pool.borrow(address(predictionToken), collateralAmount, borrowAmount);
        
        // Wait some time for interest to accrue
        vm.warp(block.timestamp + 30 days);
        
        // Repay full amount (pass 0 to repay all)
        USDC.approve(address(pool), type(uint256).max);
        
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        bytes32 positionId = StorageShell.userPositionId(marketId, borrower1);
        
        uint256 borrowerUsdcBefore = USDC.balanceOf(borrower1);
        uint256 borrowerCollateralBefore = predictionToken.balanceOf(borrower1);
        
        uint256 actualRepayAmount = pool.repay(address(predictionToken), 0);
        vm.stopPrank();
        
        // Check that debt is cleared and collateral returned
        UserPosition memory positionAfter = StorageShell.getUserPosition(positionId);
        assertEq(positionAfter.borrowAmount, 0, "Borrow amount should be 0");
        assertEq(positionAfter.scaledDebtBalance, 0, "Scaled debt should be 0");
        assertEq(positionAfter.collateralAmount, 0, "Collateral should be returned");
        
        // Check collateral was returned
        uint256 borrowerCollateralAfter = predictionToken.balanceOf(borrower1);
        assertEq(borrowerCollateralAfter - borrowerCollateralBefore, collateralAmount, "Full collateral should be returned");
        
        // Check repay amount includes interest
        assertTrue(actualRepayAmount > borrowAmount, "Repay amount should include interest");
        assertEq(borrowerUsdcBefore - USDC.balanceOf(borrower1), actualRepayAmount, "Correct amount of USDC should be deducted");
        
        // Check market state
        MarketData memory marketAfter = StorageShell.getMarketData(marketId);
        assertEq(marketAfter.totalBorrowed, 0, "Market total borrowed should be 0");
        assertEq(marketAfter.totalCollateral, 0, "Market total collateral should be 0");
    }
    
    function test_Repay_Partial_Success() public {
        // First, borrow some funds
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS;
        uint256 borrowAmount = 200 * 10 ** 6;
        
        vm.startPrank(borrower1);
        predictionToken.approve(address(pool), collateralAmount);
        pool.borrow(address(predictionToken), collateralAmount, borrowAmount);
        
        // Repay half
        uint256 repayAmount = 100 * 10 ** 6;
        USDC.approve(address(pool), repayAmount);
        
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        bytes32 positionId = StorageShell.userPositionId(marketId, borrower1);
        
        UserPosition memory positionBefore = StorageShell.getUserPosition(positionId);
        
        pool.repay(address(predictionToken), repayAmount);
        vm.stopPrank();
        
        // Check position state
        UserPosition memory positionAfter = StorageShell.getUserPosition(positionId);
        assertTrue(positionAfter.borrowAmount < positionBefore.borrowAmount, "Borrow amount should decrease");
        assertTrue(positionAfter.scaledDebtBalance < positionBefore.scaledDebtBalance, "Scaled debt should decrease");
        assertEq(positionAfter.collateralAmount, collateralAmount, "Collateral should remain");
        
        // Check market state
        MarketData memory marketAfter = StorageShell.getMarketData(marketId);
        assertTrue(marketAfter.totalBorrowed < borrowAmount, "Market total borrowed should decrease");
        assertEq(marketAfter.totalCollateral, collateralAmount, "Market total collateral should remain");
    }
    
    
    function test_Repay_NoDebt_Reverts() public {
        vm.startPrank(borrower1);
        vm.expectRevert();
        pool.repay(address(predictionToken), 100 * 10 ** 6);
        vm.stopPrank();
    }
    
    
    // ============ Helper Functions ============
}