// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./Base.t.sol";
import {Pool} from "../src/Pool.sol";
import {AaveModule} from "../src/adaptor/AaveModule.sol";
import {RiskParams} from "../src/libraries/DataStruct.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IDataProvider} from "../src/interfaces/IDataProvider.sol";
import "./mocks/MockOracle.sol";
import "./mocks/MockPredictionToken.sol";

contract FixedBorrowTest is PolynanceTest {
    Pool public pool;
    AaveModule public aaveModule;
    MockOracle public mockOracle;
    MockPredictionToken public predictionToken;
    
    address public curator = makeAddr("curator");
    address public supplier = makeAddr("supplier");
    address public borrower = makeAddr("borrower");
    
    function setUp() public override {
        super.setUp();
        
        // Deploy contracts
        mockOracle = new MockOracle();
        predictionToken = new MockPredictionToken("PRED", "PRED", 18);
        mockOracle.setPrice(address(predictionToken), 5e17); // 0.5 USD
        
        // Deploy AaveModule
        address[] memory assets = new address[](1);
        assets[0] = address(USDC);
        aaveModule = new AaveModule(assets);
        
        // Deploy pool
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
        
        // Supply liquidity
        deal(address(USDC), supplier, 10000e6);
        vm.startPrank(supplier);
        USDC.approve(address(pool), 10000e6);
        pool.supply(10000e6);
        vm.stopPrank();
        
        // Fund borrower
        predictionToken.mint(borrower, 1000e18);
        deal(address(USDC), borrower, 1000e6);
        
        // Initialize market
        vm.prank(curator);
        try pool.initializeMarket(address(predictionToken), 18) {
            console.log("Market initialized successfully");
        } catch {
            console.log("Market initialization failed");
        }
    }
    
    function test_BorrowWithProperStateAccess() public {
        console.log("=== Borrow Test with Proper State Access ===");
        
        // Get initial pool state using IDataProvider interface
        IDataProvider dataProvider = IDataProvider(address(pool));
        
        (uint256 totalSuppliedBefore, uint256 totalBorrowedBefore,,) = dataProvider.getPoolSummary();
        console.log("Initial pool state:");
        console.log("  Total supplied:", totalSuppliedBefore);
        console.log("  Total borrowed:", totalBorrowedBefore);
        
        // Get initial user position
        (uint256 collateralBefore, uint256 borrowAmountBefore, uint256 totalDebtBefore,,) = 
            dataProvider.getUserPositionSummary(borrower, address(predictionToken));
        console.log("Initial user position:");
        console.log("  Collateral:", collateralBefore);
        console.log("  Borrow amount:", borrowAmountBefore);
        console.log("  Total debt:", totalDebtBefore);
        
        // Get initial market state
        (bool isActive,, uint256 marketTotalBorrowedBefore, uint256 marketTotalCollateralBefore,,) = 
            dataProvider.getMarketSummary(address(predictionToken));
        console.log("Initial market state:");
        console.log("  Is active:", isActive);
        console.log("  Total borrowed:", marketTotalBorrowedBefore);
        console.log("  Total collateral:", marketTotalCollateralBefore);
        
        uint256 collateral = 100e18;
        uint256 borrowAmount = 20e6;
        
        // Execute borrow
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateral);
        
        console.log("\nExecuting borrow...");
        uint256 actualBorrowAmount = pool.borrow(address(predictionToken), collateral, borrowAmount);
        console.log("Borrow executed! Actual amount:", actualBorrowAmount);
        vm.stopPrank();
        
        // Get final pool state
        (uint256 totalSuppliedAfter, uint256 totalBorrowedAfter,,) = dataProvider.getPoolSummary();
        console.log("\nFinal pool state:");
        console.log("  Total supplied:", totalSuppliedAfter);
        console.log("  Total borrowed:", totalBorrowedAfter);
        
        // Get final user position
        (uint256 collateralAfter, uint256 borrowAmountAfter, uint256 totalDebtAfter,,) = 
            dataProvider.getUserPositionSummary(borrower, address(predictionToken));
        console.log("Final user position:");
        console.log("  Collateral:", collateralAfter);
        console.log("  Borrow amount:", borrowAmountAfter);
        console.log("  Total debt:", totalDebtAfter);
        
        // Get final market state
        (,, uint256 marketTotalBorrowedAfter, uint256 marketTotalCollateralAfter,,) = 
            dataProvider.getMarketSummary(address(predictionToken));
        console.log("Final market state:");
        console.log("  Total borrowed:", marketTotalBorrowedAfter);
        console.log("  Total collateral:", marketTotalCollateralAfter);
        
        // Assertions
        assertEq(actualBorrowAmount, borrowAmount, "Should borrow requested amount");
        assertEq(totalSuppliedAfter, totalSuppliedBefore, "Total supplied should not change");
        assertEq(totalBorrowedAfter, totalBorrowedBefore + borrowAmount, "Total borrowed should increase");
        assertEq(collateralAfter, collateral, "User collateral should be updated");
        assertEq(borrowAmountAfter, borrowAmount, "User borrow amount should be updated");
        assertEq(marketTotalBorrowedAfter, marketTotalBorrowedBefore + borrowAmount, "Market total borrowed should increase");
        assertEq(marketTotalCollateralAfter, marketTotalCollateralBefore + collateral, "Market total collateral should increase");
        
        // Check token balances
        assertEq(USDC.balanceOf(borrower), 1000e6 + borrowAmount, "Borrower should receive USDC");
        assertEq(predictionToken.balanceOf(borrower), 1000e18 - collateral, "Borrower should transfer collateral");
        assertEq(predictionToken.balanceOf(address(pool)), collateral, "Pool should hold collateral");
    }
    
    function test_RepayWithProperStateAccess() public {
        // First borrow
        uint256 collateral = 100e18;
        uint256 borrowAmount = 20e6;
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateral);
        pool.borrow(address(predictionToken), collateral, borrowAmount);
        
        // Wait for interest
        vm.warp(block.timestamp + 30 days);
        
        // Get state before repay
        IDataProvider dataProvider = IDataProvider(address(pool));
        (,, uint256 totalDebtBefore,,) = dataProvider.getUserPositionSummary(borrower, address(predictionToken));
        console.log("Total debt before repay:", totalDebtBefore);
        
        // Repay all
        USDC.approve(address(pool), type(uint256).max);
        uint256 repaidAmount = pool.repay(address(predictionToken), 0);
        vm.stopPrank();
        
        console.log("Repaid amount:", repaidAmount);
        assertTrue(repaidAmount >= borrowAmount, "Repaid amount should include interest");
        
        // Check final state
        (uint256 collateralAfter, uint256 borrowAmountAfter, uint256 totalDebtAfter,,) = 
            dataProvider.getUserPositionSummary(borrower, address(predictionToken));
        
        assertEq(collateralAfter, 0, "Collateral should be returned");
        assertEq(borrowAmountAfter, 0, "Borrow amount should be zero");
        assertEq(totalDebtAfter, 0, "Total debt should be zero");
        assertEq(predictionToken.balanceOf(borrower), 1000e18, "All collateral should be returned");
    }
}