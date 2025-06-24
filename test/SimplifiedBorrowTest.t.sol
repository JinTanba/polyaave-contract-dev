// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./Base.t.sol";
import {Pool} from "../src/Pool.sol";
import {AaveModule} from "../src/adaptor/AaveModule.sol";
import {RiskParams} from "../src/libraries/DataStruct.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./mocks/MockOracle.sol";
import "./mocks/MockPredictionToken.sol";

contract SimplifiedBorrowTest is PolynanceTest {
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
        } catch Error(string memory reason) {
            console.log("Market initialization failed:", reason);
        } catch (bytes memory) {
            console.log("Market initialization failed with low-level error");
        }
    }
    
    function test_SimpleBorrow() public {
        console.log("=== Simple Borrow Test ===");
        console.log("Borrower PRED balance:", predictionToken.balanceOf(borrower));
        console.log("Borrower USDC balance:", USDC.balanceOf(borrower));
        console.log("Pool USDC balance:", USDC.balanceOf(address(pool)));
        console.log("AaveModule USDC balance:", USDC.balanceOf(address(aaveModule)));
        
        uint256 collateral = 100e18;
        uint256 borrowAmount = 20e6;
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateral);
        
        console.log("\nAttempting to borrow...");
        pool.borrow(address(predictionToken), collateral, borrowAmount);
        vm.stopPrank();
        
        console.log("\nAfter borrow:");
        console.log("Borrower PRED balance:", predictionToken.balanceOf(borrower));
        console.log("Borrower USDC balance:", USDC.balanceOf(borrower));
    }
}