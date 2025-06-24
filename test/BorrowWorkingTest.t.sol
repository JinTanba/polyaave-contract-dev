// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./Supply.t.sol";
import {MarketData, UserPosition, DataType} from "../src/libraries/DataStruct.sol";
import {StorageShell} from "../src/libraries/StorageShell.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import "./mocks/MockOracle.sol";
import "./mocks/MockPredictionToken.sol";

// Extend SupplyTest which already has a working pool setup
contract BorrowWorkingTest is SupplyTest {
    using WadRayMath for uint256;
    
    MockOracle public mockOracle;
    MockPredictionToken public predictionToken;
    address public borrower;
    
    uint256 constant PREDICTION_TOKEN_PRICE = 5e17; // 0.5 in Wad
    uint256 constant PREDICTION_TOKEN_DECIMALS = 18;
    
    function setUp() public override {
        super.setUp();
        
        borrower = makeAddr("borrower");
        
        // Replace oracle with mock
        mockOracle = new MockOracle();
        
        // Create new pool with mock oracle
        RiskParams memory riskParams = RiskParams({
            priceOracle: address(mockOracle),
            liquidityLayer: address(aaveModule),
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
        pool = new Pool("POLYLP", "POLYLP", riskParams);
        
        // Deploy prediction token
        predictionToken = new MockPredictionToken("PRED", "PRED", uint8(PREDICTION_TOKEN_DECIMALS));
        mockOracle.setPrice(address(predictionToken), PREDICTION_TOKEN_PRICE);
        
        // Initialize market data directly
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        
        // Set up the market in storage (bypass initialization)
        // We need to store the market data at the correct storage slot
        MarketData memory market;
        market.collateralAsset = address(predictionToken);
        market.collateralAssetDecimals = PREDICTION_TOKEN_DECIMALS;
        market.variableBorrowIndex = 1e27;
        market.lastUpdateTimestamp = block.timestamp;
        market.isActive = true;
        
        // Calculate storage slot for market data
        // slot = keccak256(abi.encode(marketId, DataType.MARKET_DATA))
        bytes32 slot = keccak256(abi.encode(marketId, uint256(DataType.MARKET_DATA)));
        
        // Store each field of MarketData struct
        vm.store(address(pool), slot, bytes32(uint256(uint160(address(predictionToken))))); // collateralAsset
        vm.store(address(pool), bytes32(uint256(slot) + 1), bytes32(PREDICTION_TOKEN_DECIMALS)); // collateralAssetDecimals
        vm.store(address(pool), bytes32(uint256(slot) + 2), bytes32(0)); // maturityDate
        vm.store(address(pool), bytes32(uint256(slot) + 3), bytes32(uint256(1e27))); // variableBorrowIndex
        vm.store(address(pool), bytes32(uint256(slot) + 4), bytes32(0)); // totalScaledBorrowed
        vm.store(address(pool), bytes32(uint256(slot) + 5), bytes32(0)); // totalBorrowed
        vm.store(address(pool), bytes32(uint256(slot) + 6), bytes32(0)); // totalCollateral
        vm.store(address(pool), bytes32(uint256(slot) + 7), bytes32(block.timestamp)); // lastUpdateTimestamp
        vm.store(address(pool), bytes32(uint256(slot) + 8), bytes32(0)); // accumulatedSpread
        vm.store(address(pool), bytes32(uint256(slot) + 9), bytes32(uint256(1))); // isActive = true
        vm.store(address(pool), bytes32(uint256(slot) + 10), bytes32(0)); // isMatured = false
        
        // Supply liquidity
        deal(address(USDC), user1, 10000e6);
        vm.startPrank(user1);
        USDC.approve(address(pool), 10000e6);
        pool.supply(10000e6);
        vm.stopPrank();
        
        // Fund borrower
        predictionToken.mint(borrower, 1000e18);
        deal(address(USDC), borrower, 1000e6);
    }
    
    function test_Borrow_Simple() public {
        uint256 collateral = 100e18; // $50 worth
        uint256 borrowAmount = 20e6; // $20
        
        uint256 balanceBefore = USDC.balanceOf(borrower);
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateral);
        
        uint256 borrowed = pool.borrow(address(predictionToken), collateral, borrowAmount);
        vm.stopPrank();
        
        assertEq(borrowed, borrowAmount, "Should borrow exact amount");
        assertEq(USDC.balanceOf(borrower) - balanceBefore, borrowAmount, "Should receive USDC");
    }
    
    function test_Repay_Simple() public {
        // First borrow
        uint256 collateral = 100e18;
        uint256 borrowAmount = 20e6;
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateral);
        pool.borrow(address(predictionToken), collateral, borrowAmount);
        
        // Then repay
        USDC.approve(address(pool), borrowAmount + 1e6); // Extra for interest
        uint256 repaid = pool.repay(address(predictionToken), borrowAmount);
        vm.stopPrank();
        
        assertTrue(repaid >= borrowAmount, "Should repay at least borrowed amount");
    }
    
    function test_Borrow_MaxLTV() public {
        uint256 collateral = 100e18; // $50 worth
        // With 60% LTV, max borrow should be $30 = 30e6
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateral);
        
        uint256 borrowed = pool.borrow(address(predictionToken), collateral, 0); // 0 = max
        vm.stopPrank();
        
        // Should be approximately 30 USDC (60% of $50)
        assertApproxEqAbs(borrowed, 30e6, 1e6, "Should borrow 60% of collateral value");
    }
    
    function test_Borrow_ExceedsLTV_Reverts() public {
        uint256 collateral = 100e18; // $50 worth
        uint256 borrowAmount = 40e6; // $40 (80% LTV)
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateral);
        
        vm.expectRevert();
        pool.borrow(address(predictionToken), collateral, borrowAmount);
        vm.stopPrank();
    }
}