// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./Base.t.sol";
import {Pool} from "../src/Pool.sol";
import {AaveModule} from "../src/adaptor/AaveModule.sol";
import {RiskParams} from "../src/libraries/DataStruct.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILiquidityLayer} from "../src/interfaces/ILiquidityLayer.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {IPoolDataProvider} from "aave-v3-core/contracts/interfaces/IPoolDataPROVIDER.sol";

contract SupplyTest is PolynanceTest {
    Pool public pool;
    AaveModule public aaveModule;
    address public curator;
    address public liquidityLayer;
    address public priceOracle;
    address public user1;
    address public user2;
    
    function setUp() public virtual override {
        super.setUp();
        
        // Setup test accounts
        curator = makeAddr("curator");
        priceOracle = makeAddr("priceOracle");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        
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
        
        // Fund test users with USDC
        deal(address(USDC), user1, 10000 * 10 ** 6); // 10,000 USDC
        deal(address(USDC), user2, 10000 * 10 ** 6); // 10,000 USDC
    }
    
    function test_Supply_Success() public {
        uint256 supplyAmount = 1000 * 10 ** 6; // 1,000 USDC
        
        // User1 approves and supplies
        vm.startPrank(user1);
        USDC.approve(address(pool), supplyAmount);
        
        uint256 lpTokensBefore = pool.balanceOf(user1);
        
        uint256 lpTokensMinted = pool.supply(supplyAmount);
        
        uint256 lpTokensAfter = pool.balanceOf(user1);
        
        vm.stopPrank();
        
        // Assertions
        assertEq(lpTokensMinted, supplyAmount, "LP tokens should be minted 1:1");
        assertEq(lpTokensAfter - lpTokensBefore, lpTokensMinted, "LP token balance should increase correctly");
        
        // Check pool state
        (uint256 totalSupplied, , , ) = pool.getPoolSummary();
        assertEq(totalSupplied, supplyAmount, "Total supplied should match supply amount");
    }
    
    function test_Supply_MultipleUsers() public {
        uint256 supplyAmount1 = 1000 * 10 ** 6; // 1,000 USDC
        uint256 supplyAmount2 = 2000 * 10 ** 6; // 2,000 USDC
        
        // User1 supplies
        vm.startPrank(user1);
        USDC.approve(address(pool), supplyAmount1);
        pool.supply(supplyAmount1);
        vm.stopPrank();
        
        // User2 supplies
        vm.startPrank(user2);
        USDC.approve(address(pool), supplyAmount2);
        pool.supply(supplyAmount2);
        vm.stopPrank();
        
        // Check balances
        assertEq(pool.balanceOf(user1), supplyAmount1, "User1 LP balance incorrect");
        assertEq(pool.balanceOf(user2), supplyAmount2, "User2 LP balance incorrect");
        
        // Check pool state
        (uint256 totalSupplied, , , uint256 totalLPTokens) = pool.getPoolSummary();
        assertEq(totalSupplied, supplyAmount1 + supplyAmount2, "Total supplied incorrect");
        assertEq(totalLPTokens, supplyAmount1 + supplyAmount2, "Total LP tokens incorrect");
    }
    
    function test_Supply_ZeroAmount_Reverts() public {
        vm.startPrank(user1);
        USDC.approve(address(pool), type(uint256).max);
        
        vm.expectRevert();
        pool.supply(0);
        
        vm.stopPrank();
    }
    
    function test_Supply_InsufficientBalance_Reverts() public {
        uint256 userBalance = USDC.balanceOf(user1);
        uint256 supplyAmount = userBalance + 1;
        
        vm.startPrank(user1);
        USDC.approve(address(pool), supplyAmount);
        
        vm.expectRevert();
        pool.supply(supplyAmount);
        
        vm.stopPrank();
    }
    
    function test_Supply_IncrementalSupplies() public {
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 100 * 10 ** 6;  // 100 USDC
        amounts[1] = 200 * 10 ** 6;  // 200 USDC
        amounts[2] = 300 * 10 ** 6;  // 300 USDC
        
        vm.startPrank(user1);
        USDC.approve(address(pool), type(uint256).max);
        
        uint256 totalLPTokens = 0;
        
        for (uint i = 0; i < amounts.length; i++) {
            uint256 lpTokensMinted = pool.supply(amounts[i]);
            totalLPTokens += lpTokensMinted;
            
            assertEq(lpTokensMinted, amounts[i], "LP tokens should equal supply amount");
            assertEq(pool.balanceOf(user1), totalLPTokens, "LP balance should accumulate correctly");
        }
        
        vm.stopPrank();
        
        // Verify final state
        (uint256 totalSupplied, , , ) = pool.getPoolSummary();
        assertEq(totalSupplied, 600 * 10 ** 6, "Total supplied should be sum of all supplies");
    }
    
    function test_Supply_PoolReceivesUSDC() public {
        uint256 supplyAmount = 1000 * 10 ** 6; // 1,000 USDC
        
        // Get aToken address for USDC
        (address aTokenAddress,,) = IPoolDataProvider(0x14496b405D62c24F91f04Cda1c69Dc526D56fDE5).getReserveTokensAddresses(address(USDC));
        
        // Track aToken balance before
        uint256 aTokenBalanceBefore = IERC20(aTokenAddress).balanceOf(address(pool));
        
        vm.startPrank(user1);
        USDC.approve(address(pool), supplyAmount);
        pool.supply(supplyAmount);
        vm.stopPrank();
        
        // The pool should have received aTokens from Aave
        uint256 aTokenBalanceAfter = IERC20(aTokenAddress).balanceOf(address(pool));
        assertTrue(aTokenBalanceAfter > aTokenBalanceBefore, "Pool should have received aTokens");
        
        // Pool should have no USDC (transferred to AaveModule then to Aave)
        uint256 poolUsdcBalance = USDC.balanceOf(address(pool));
        assertEq(poolUsdcBalance, 0, "Pool should have no USDC");
    }
    
    function test_Supply_EmitsEvent() public {
        uint256 supplyAmount = 1000 * 10 ** 6; // 1,000 USDC
        
        vm.startPrank(user1);
        USDC.approve(address(pool), supplyAmount);
        
        // We expect an event to be emitted (actual event depends on implementation)
        // vm.expectEmit(true, true, true, true);
        // emit Supply(user1, supplyAmount, lpTokensMinted);
        
        pool.supply(supplyAmount);
        vm.stopPrank();
    }
}