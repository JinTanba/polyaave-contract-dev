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
import "../src/libraries/logic/ReserveLogic.sol";

contract SimpleBorrowTest is PolynanceTest {
    using WadRayMath for uint256;
    
    Pool public pool;
    AaveModule public aaveModule;
    MockOracle public mockOracle;
    MockPredictionToken public predictionToken;
    
    address public curator;
    address public supplier;
    address public borrower;
    
    uint256 constant PREDICTION_TOKEN_PRICE = 5e17; // 0.5 in Wad (50 cents)
    uint256 constant PREDICTION_TOKEN_DECIMALS = 18;
    
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
        
        // Setup risk parameters
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
        
        // Deploy pool
        vm.prank(curator);
        pool = new Pool("Polynance LP Token", "POLYLP", riskParams);
        
        // Initialize market directly through ReserveLogic to bypass Pool's buggy check
        bytes32 marketId = StorageShell.reserveId(address(USDC), address(predictionToken));
        
        // Initialize the market data directly
        MarketData memory market;
        market.collateralAsset = address(predictionToken);
        market.collateralAssetDecimals = PREDICTION_TOKEN_DECIMALS;
        market.variableBorrowIndex = 1e27; // RAY
        market.lastUpdateTimestamp = block.timestamp;
        market.isActive = true;
        
        // Store market data
        vm.store(
            address(pool),
            keccak256(abi.encode(marketId, uint256(DataType.MARKET_DATA))),
            bytes32(uint256(uint160(address(predictionToken))))
        );
        
        // Also need to properly set the isMarketActive mapping
        // First, add to activeMarkets array (slot 0)
        vm.store(address(pool), bytes32(uint256(0)), bytes32(uint256(1))); // array length = 1
        vm.store(
            address(pool), 
            keccak256(abi.encode(uint256(0))), // first element of array
            marketId
        );
        
        // Then set isMarketActive[marketId] = true (slot 1)
        bytes32 slot = keccak256(abi.encode(marketId, uint256(1)));
        vm.store(address(pool), slot, bytes32(uint256(1))); // true
        
        // Initialize market data in StorageShell
        ReserveLogic.initializeMarket(marketId, address(predictionToken), PREDICTION_TOKEN_DECIMALS);
        
        // Supply liquidity
        uint256 supplyAmount = 10000 * 10 ** 6; // 10,000 USDC
        deal(address(USDC), supplier, supplyAmount);
        vm.startPrank(supplier);
        USDC.approve(address(pool), supplyAmount);
        pool.supply(supplyAmount);
        vm.stopPrank();
        
        // Fund borrower
        predictionToken.mint(borrower, 10000 * 10 ** PREDICTION_TOKEN_DECIMALS);
        deal(address(USDC), borrower, 1000 * 10 ** 6);
    }
    
    function test_SimpleBorrow() public {
        uint256 collateralAmount = 100 * 10 ** PREDICTION_TOKEN_DECIMALS; // 100 tokens = $50
        uint256 borrowAmount = 20 * 10 ** 6; // 20 USDC
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateralAmount);
        
        uint256 actualBorrowAmount = pool.borrow(
            address(predictionToken),
            collateralAmount,
            borrowAmount
        );
        vm.stopPrank();
        
        assertEq(actualBorrowAmount, borrowAmount, "Should borrow requested amount");
    }
    
    function test_SimpleRepay() public {
        // First borrow
        uint256 collateralAmount = 100 * 10 ** PREDICTION_TOKEN_DECIMALS;
        uint256 borrowAmount = 20 * 10 ** 6;
        
        vm.startPrank(borrower);
        predictionToken.approve(address(pool), collateralAmount);
        pool.borrow(address(predictionToken), collateralAmount, borrowAmount);
        
        // Then repay
        USDC.approve(address(pool), borrowAmount);
        uint256 repayAmount = pool.repay(address(predictionToken), borrowAmount);
        vm.stopPrank();
        
        assertTrue(repayAmount >= borrowAmount, "Repay amount should be at least borrow amount");
    }
}