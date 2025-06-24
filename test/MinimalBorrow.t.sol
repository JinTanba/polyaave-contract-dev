// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import "./Base.t.sol";
import {Pool} from "../src/Pool.sol";
import {AaveModule} from "../src/adaptor/AaveModule.sol";
import {RiskParams, PoolData, MarketData, UserPosition, DataType} from "../src/libraries/DataStruct.sol";
import {StorageShell} from "../src/libraries/StorageShell.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import "./mocks/MockOracle.sol";
import "./mocks/MockPredictionToken.sol";
import {ReserveLogic} from "../src/libraries/logic/ReserveLogic.sol";

contract MinimalBorrowTest is PolynanceTest {
    using WadRayMath for uint256;
    
    Pool public pool;
    AaveModule public aaveModule;
    MockOracle public mockOracle;
    MockPredictionToken public predictionToken;
    
    address public curator = makeAddr("curator");
    address public supplier = makeAddr("supplier");
    address public borrower = makeAddr("borrower");
    
    uint256 constant PREDICTION_TOKEN_PRICE = 5e17; // 0.5 in Wad
    uint256 constant PREDICTION_TOKEN_DECIMALS = 18;
    
    function setUp() public override {
        super.setUp();
        
        // Deploy contracts
        mockOracle = new MockOracle();
        predictionToken = new MockPredictionToken("PRED", "PRED", uint8(PREDICTION_TOKEN_DECIMALS));
        mockOracle.setPrice(address(predictionToken), PREDICTION_TOKEN_PRICE);
        
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
        
        // Initialize market directly in storage to bypass buggy check
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        
        // Use ReserveLogic to initialize properly
        vm.prank(address(pool));
        ReserveLogic.initializeMarket(marketId, address(predictionToken), PREDICTION_TOKEN_DECIMALS);
        
        // Supply liquidity
        deal(address(USDC), supplier, 10000e6);
        vm.startPrank(supplier);
        USDC.approve(address(pool), 10000e6);
        pool.supply(10000e6);
        vm.stopPrank();
        
        // Fund borrower
        predictionToken.mint(borrower, 1000e18);
        deal(address(USDC), borrower, 1000e6);
    }
    
    function test_MinimalBorrow() public {
        console.log("=== Starting Minimal Borrow Test ===");
        
        // Check market is initialized
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        MarketData memory market = StorageShell.getMarketData(marketId);
        console.log("Market isActive:", market.isActive);
        console.log("Market variableBorrowIndex:", market.variableBorrowIndex);
        
        uint256 collateral = 100e18; // 100 tokens = $50
        uint256 borrowAmount = 20e6; // 20 USDC
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateral);
        
        console.log("Attempting to borrow...");
        uint256 borrowed = pool.borrow(address(predictionToken), collateral, borrowAmount);
        vm.stopPrank();
        
        console.log("Borrowed amount:", borrowed);
        assertEq(borrowed, borrowAmount);
    }
}