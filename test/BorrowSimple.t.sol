// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./Supply.t.sol";
import {MarketData, UserPosition} from "../src/libraries/DataStruct.sol";
import {StorageShell} from "../src/libraries/StorageShell.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import "./mocks/MockOracle.sol";
import "./mocks/MockPredictionToken.sol";

contract BorrowSimpleTest is SupplyTest {
    using WadRayMath for uint256;
    
    MockOracle public mockOracle;
    MockPredictionToken public predictionToken;
    address public borrower1;
    address public borrower2;
    
    uint256 constant PREDICTION_TOKEN_PRICE = 5e17; // 0.5 in Wad (50 cents)
    uint256 constant PREDICTION_TOKEN_DECIMALS = 18;
    
    function setUp() public override {
        super.setUp();
        
        // Setup borrowers
        borrower1 = makeAddr("borrower1");
        borrower2 = makeAddr("borrower2");
        
        // Replace the price oracle with our mock
        mockOracle = new MockOracle();
        
        // Deploy prediction token
        predictionToken = new MockPredictionToken("Prediction Token", "PRED", uint8(PREDICTION_TOKEN_DECIMALS));
        
        // Set prediction token price in oracle
        mockOracle.setPrice(address(predictionToken), PREDICTION_TOKEN_PRICE);
        
        // Update pool to use our mock oracle
        // Note: This is a limitation - we can't update the oracle after deployment
        // So we'll need to deploy a new pool with our mock oracle
        
        // Deploy new pool with mock oracle
        RiskParams memory riskParams = RiskParams({
            priceOracle: address(mockOracle),
            liquidityLayer: liquidityLayer,
            supplyAsset: address(USDC),
            curator: curator,
            baseSpreadRate: 1e25,
            optimalUtilization: 8e26,
            slope1: 5e25,
            slope2: 1e27,
            reserveFactor: 1e26,
            ltv: 6000,
            liquidationThreshold: 7500,
            liquidationCloseFactor: 5000,
            liquidationBonus: 1000,
            lpShareOfRedeemed: 8000,
            supplyAssetDecimals: 6
        });
        
        vm.prank(curator);
        pool = new Pool("Polynance LP Token", "POLYLP", riskParams);
        
        // Initialize market properly
        vm.prank(curator);
        pool.initializeMarket(address(predictionToken), PREDICTION_TOKEN_DECIMALS);
        
        // Supply liquidity first
        uint256 supplyAmount = 10000 * 10 ** 6; // 10,000 USDC
        deal(address(USDC), user1, supplyAmount);
        vm.startPrank(user1);
        USDC.approve(address(pool), supplyAmount);
        pool.supply(supplyAmount);
        vm.stopPrank();
        
        // Fund borrowers with prediction tokens
        predictionToken.mint(borrower1, 10000 * 10 ** PREDICTION_TOKEN_DECIMALS);
        predictionToken.mint(borrower2, 10000 * 10 ** PREDICTION_TOKEN_DECIMALS);
        
        // Fund borrowers with some USDC for repayments
        deal(address(USDC), borrower1, 10000 * 10 ** 6);
        deal(address(USDC), borrower2, 10000 * 10 ** 6);
    }
    
    function test_Borrow_Basic() public {
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS; // 1,000 tokens
        uint256 borrowAmount = 200 * 10 ** 6; // 200 USDC
        
        uint256 borrowerUsdcBefore = USDC.balanceOf(borrower1);
        
        vm.startPrank(borrower1);
        predictionToken.approve(address(pool), collateralAmount);
        
        uint256 actualBorrowAmount = pool.borrow(
            address(predictionToken),
            collateralAmount,
            borrowAmount
        );
        vm.stopPrank();
        
        uint256 borrowerUsdcAfter = USDC.balanceOf(borrower1);
        
        assertEq(actualBorrowAmount, borrowAmount, "Should borrow requested amount");
        assertEq(borrowerUsdcAfter - borrowerUsdcBefore, borrowAmount, "Borrower should receive USDC");
    }
    
    function test_Repay_Basic() public {
        // First borrow
        uint256 collateralAmount = 1000 * 10 ** PREDICTION_TOKEN_DECIMALS;
        uint256 borrowAmount = 200 * 10 ** 6;
        
        vm.startPrank(borrower1);
        predictionToken.approve(address(pool), collateralAmount);
        pool.borrow(address(predictionToken), collateralAmount, borrowAmount);
        
        // Then repay all
        USDC.approve(address(pool), type(uint256).max);
        uint256 actualRepayAmount = pool.repay(address(predictionToken), 0);
        vm.stopPrank();
        
        assertTrue(actualRepayAmount >= borrowAmount, "Repay amount should include any interest");
        
        // Check collateral was returned
        assertEq(predictionToken.balanceOf(borrower1), 10000 * 10 ** PREDICTION_TOKEN_DECIMALS, "All collateral should be returned");
    }
}