// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {WadRayMath} from "@aave/protocol/libraries/math/WadRayMath.sol";
import {IPoolAddressesProvider} from "aave-v3-core/contracts/interfaces/IPoolAddressesPROVIDER.sol";
import {ICreditDelegationToken} from "aave-v3-core/contracts/interfaces/ICreditDelegationToken.sol";
import {DataTypes} from "aave-v3-core/contracts/protocol/libraries/types/DataTypes.sol";
import "./interfaces/IPool.sol";
import "./interfaces/IDataProvider.sol";
import "./libraries/DataStruct.sol";
import "./libraries/StorageShell.sol";
import "./libraries/PolynanceEE.sol";
import {AaveLibrary} from "./adaptor/AaveModule.sol";
// Import logic libraries
import "./libraries/logic/MarketResolveLogic.sol";
import "./libraries/logic/SupplyLogic.sol";
import "./libraries/logic/BorrowLogic.sol";
import "./libraries/logic/LiquidationLogic.sol";
import "./libraries/logic/ReserveLogic.sol";

// Import Core for inheritance
import "./core/Core.sol";
import "./core/CoreMath.sol";

// Import interfaces
import "./interfaces/ILiquidityLayer.sol";
import "./interfaces/IOracle.sol";

/**
 * @title Pool
 * @notice Main Pool contract implementing IPool interface
 * @dev Inherits from Core for state transition functions and ERC20 for LP tokens
 */
contract Pool is IPool, IDataProvider, Core, ERC20, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    
    // Track active markets for index updates
    bytes32[] private activeMarkets;
    mapping(bytes32 => bool) private isMarketActive;
    
    // Modifier for curator-only functions
    modifier onlyCurator() {
        RiskParams memory params = StorageShell.getRiskParams();
        if (msg.sender != params.curator) revert PolynanceEE.NotCurator();
        _;
    }
    
    /**
     * @notice Constructor
     * @param _name LP token name
     * @param _symbol LP token symbol
     * @param _riskParams Initial risk parameters
     */
    constructor(
        string memory _name,
        string memory _symbol,
        RiskParams memory _riskParams
    ) ERC20(_name, _symbol) {
        // Initialize risk parameters
        StorageShell.next(DataType.RISK_PARAMS, abi.encode(_riskParams), StorageShell.ZERO_ID);
        
        PoolData memory initialPool;
        StorageShell.next(DataType.POOL_DATA, abi.encode(initialPool), StorageShell.ZERO_ID);

        IERC20(_riskParams.supplyAsset).approve(_riskParams.liquidityLayer, type(uint256).max);
        ICreditDelegationToken(AaveLibrary.POOL.getReserveData(_riskParams.supplyAsset).variableDebtTokenAddress).approveDelegation(_riskParams.liquidityLayer,type(uint256).max);
    }
    
    // ============ Core Functions ============
    
    /**
     * @notice Supply liquidity to the pool
     * @param amount Amount of supply asset to deposit
     * @return lpTokensMinted Amount of LP tokens minted
     */
    function supply(uint256 amount) external override nonReentrant returns (uint256 lpTokensMinted) {
        // Call SupplyLogic
        lpTokensMinted = SupplyLogic.supply(
            msg.sender,
            amount,
            balanceOf(msg.sender),
            activeMarkets
        );
        
        // Mint LP tokens
        _mint(msg.sender, lpTokensMinted);
        
        return lpTokensMinted;
    }
    
    /**
     * @notice Borrow against collateral
     * @param predictionAsset Address of the prediction token
     * @param collateralAmount Amount of prediction tokens to deposit
     * @param borrowAmount Amount to borrow
     * @return actualBorrowAmount Amount actually borrowed
     */
    function borrow(
        address predictionAsset,
        uint256 collateralAmount,
        uint256 borrowAmount
    ) external override nonReentrant returns (uint256 actualBorrowAmount) {
        // Ensure market is initialized
        _ensureMarketInitialized(predictionAsset);
        
        // Call BorrowLogic
        actualBorrowAmount = BorrowLogic.borrow(
            msg.sender,
            collateralAmount,
            borrowAmount,
            predictionAsset
        );
        
        return actualBorrowAmount;
    }
    
    /**
     * @notice Repay borrowed amount
     * @param predictionAsset Address of the prediction token
     * @param repayAmount Amount to repay
     * @return actualRepayAmount Amount actually repaid
     */
    function repay(
        address predictionAsset,
        uint256 repayAmount
    ) external override nonReentrant returns (uint256 actualRepayAmount) {
        // Call BorrowLogic.repay
        actualRepayAmount = BorrowLogic.repay(
            msg.sender,
            repayAmount,
            predictionAsset
        );
        
        return actualRepayAmount;
    }
    
    /**
     * @notice Liquidate an undercollateralized position
     * @param user Address being liquidated
     * @param predictionAsset The prediction token used as collateral
     * @param debtToCover Amount of debt to repay
     * @return actualDebtRepaid Actual amount of debt repaid
     * @return collateralSeized Amount of collateral seized
     */
    function liquidate(
        address user,
        address predictionAsset,
        uint256 debtToCover
    ) external override nonReentrant returns (
        uint256 actualDebtRepaid,
        uint256 collateralSeized
    ) {
        // Call LiquidationLogic
        (actualDebtRepaid, collateralSeized) = LiquidationLogic.liquidate(
            msg.sender,
            user,
            debtToCover,
            predictionAsset
        );
        
        return (actualDebtRepaid, collateralSeized);
    }
    
    // ============ Resolution Functions ============
    
    /**
     * @notice Resolve a prediction market
     * @param predictionAsset The prediction token being resolved
     */
    function resolveMarket(address predictionAsset) external override nonReentrant onlyCurator {
        // Call MarketResolveLogic
        MarketResolveLogic.resolve(msg.sender, predictionAsset);
    }
    
    /**
     * @notice Claim borrower's rebate after resolution
     * @param predictionAsset The prediction token
     * @return rebateAmount Amount of rebate claimed
     */
    function claimBorrowerPosition(
        address predictionAsset
    ) external override nonReentrant returns (uint256 rebateAmount) {
        // Call MarketResolveLogic
        rebateAmount = MarketResolveLogic.claimBorrowerPosition(
            msg.sender,
            predictionAsset
        );
        
        return rebateAmount;
    }
    
    /**
     * @notice Claim LP position after resolution
     * @param lpTokenAmount Amount of LP tokens to redeem
     * @return totalPayout Total amount paid to LP
     */
    function claimLPPosition(
        uint256 lpTokenAmount
    ) external override nonReentrant returns (uint256 totalPayout) {
        // Verify LP token balance
        if (balanceOf(msg.sender) < lpTokenAmount) revert PolynanceEE.InvalidAmount();
        
        // Call MarketResolveLogic
        totalPayout = MarketResolveLogic.claimLPPosition(
            msg.sender,
            lpTokenAmount,
            totalSupply()
        );
        
        // Burn LP tokens
        _burn(msg.sender, lpTokenAmount);
        
        return totalPayout;
    }
    
    /**
     * @notice Claim protocol revenues
     * @return protocolAmount Amount claimed
     */
    function claimProtocolRevenue() external override nonReentrant onlyCurator returns (uint256 protocolAmount) {
        // Call MarketResolveLogic
        protocolAmount = MarketResolveLogic.claimProtocolRevenue(msg.sender);
        
        return protocolAmount;
    }
    
    // ============ Admin Functions ============
    
    /**
     * @notice Initialize a new prediction market
     * @param predictionAsset The prediction token address
     * @param collateralDecimals The collateral asset decimals
     */
    function initializeMarket(
        address predictionAsset,
        uint256 collateralDecimals
    ) external override onlyCurator {
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        
        // Check if already initialized
        if (isMarketActive[marketId]) revert PolynanceEE.MarketAlreadyInitialized();
        
        // Initialize market using ReserveLogic
        ReserveLogic.initializeMarket(marketId, predictionAsset, collateralDecimals);
        
        // Add to active markets
        activeMarkets.push(marketId);
        isMarketActive[marketId] = true;
        
        emit PolynanceEE.DepositCollateral(address(this), predictionAsset, 0);
    }
    
    // ============ Internal Functions ============
    
    /**
     * @notice Ensure market is initialized before operations
     * @param predictionAsset The prediction token
     */
    function _ensureMarketInitialized(address predictionAsset) internal view {
        RiskParams memory params = StorageShell.getRiskParams();
        // bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        
        // if (!isMarketActive[marketId]) revert PolynanceEE.MarketNotActive();
    }
    
    // ============ View Functions (minimal for now) ============
    
    /**
     * @notice Get all active market IDs
     * @return Array of active market IDs
     */
    function getActiveMarkets() external view returns (bytes32[] memory) {
        return activeMarkets;
    }
    
    /**
     * @notice Check if a market is active
     * @param predictionAsset The prediction token
     * @return True if market is active
     */
    function isMarketActiveCheck(address predictionAsset) external view returns (bool) {
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        return isMarketActive[marketId];
    }
    
    // ============ IDataProvider Implementation ============
    
    /**
     * @notice Get user's position summary
     */
    function getUserPositionSummary(
        address user,
        address predictionAsset
    ) external view override returns (
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 totalDebt,
        uint256 healthFactor,
        uint256 maxBorrowable
    ) {
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        bytes32 positionId = StorageShell.userPositionId(marketId, user);
        
        // Get updated indices without storing
        (MarketData memory market, PoolData memory pool) = ReserveLogic.getUpdatedMarketIndices(marketId);
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        collateralAmount = position.collateralAmount;
        borrowAmount = position.borrowAmount;
        
        if (position.scaledDebtBalance > 0) {
            // Get protocol total debt from liquidity layer
            uint256 protocolTotalDebt = ILiquidityLayer(params.liquidityLayer)
                .getTotalDebt(params.supplyAsset, address(this));
                
            (totalDebt, , ) = getUserDebt(market, pool, position, protocolTotalDebt);
            
            // Get health factor
            uint256 currentPriceWad = IOracle(params.priceOracle).getCurrentPrice(predictionAsset);
            uint256 currentPriceRay = currentPriceWad.wadToRay();
            
            healthFactor = getUserHealthFactor(
                market,
                pool,
                position,
                currentPriceRay,
                protocolTotalDebt,
                params
            );
        } else {
            totalDebt = 0;
            healthFactor = type(uint256).max;
        }
        
        // Calculate max borrowable
        (maxBorrowable, ) = BorrowLogic.getBorrowingCapacity(user, predictionAsset);
        if (borrowAmount >= maxBorrowable) {
            maxBorrowable = 0;
        } else {
            maxBorrowable = maxBorrowable - borrowAmount;
        }
        
        return (collateralAmount, borrowAmount, totalDebt, healthFactor, maxBorrowable);
    }

    
    /**
     * @notice Get market summary
     */
    function getMarketSummary(
        address predictionAsset
    ) external view override returns (
        bool isActive,
        bool isResolved,
        uint256 totalBorrowed,
        uint256 totalCollateral,
        uint256 utilizationRate,
        uint256 spreadRate
    ) {
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        
        // Get updated indices
        (MarketData memory market, PoolData memory pool) = ReserveLogic.getUpdatedMarketIndices(marketId);
        ResolutionData memory resolution = StorageShell.getResolutionData(marketId);
        
        isActive = market.isActive;
        isResolved = resolution.isMarketResolved;
        totalBorrowed = market.totalBorrowed;
        totalCollateral = market.totalCollateral;
        
        // Calculate utilization and spread rate
        utilizationRate = getUtilization(market, pool);
        spreadRate = getSpreadRate(market, pool, params);
        
        return (isActive, isResolved, totalBorrowed, totalCollateral, utilizationRate, spreadRate);
    }
    
    /**
     * @notice Get pool summary
     */
    function getPoolSummary() external view override returns (
        uint256 totalSupplied,
        uint256 totalBorrowed,
        uint256 availableLiquidity,
        uint256 totalLPTokens
    ) {
        PoolData memory pool = StorageShell.getPool();
        totalSupplied = pool.totalSupplied;
        totalBorrowed = pool.totalBorrowedAllMarkets;
        availableLiquidity = totalSupplied > totalBorrowed ? totalSupplied - totalBorrowed : 0;
        totalLPTokens = totalSupply();
        
        return (totalSupplied, totalBorrowed, availableLiquidity, totalLPTokens);
    }
    
    /**
     * @notice Get claimable amounts after resolution
     */
    function getClaimableAmounts(
        address user,
        address predictionAsset
    ) external view override returns (
        uint256 borrowerClaimable,
        uint256 lpClaimable
    ) {
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        bytes32 positionId = StorageShell.userPositionId(marketId, user);
        
        ResolutionData memory resolution = StorageShell.getResolutionData(marketId);
        MarketData memory market = StorageShell.getMarketData(marketId);
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        // Calculate borrower claimable
        if (resolution.isMarketResolved && position.collateralAmount > 0) {
            borrowerClaimable = calculateBorrowerRebate(market, resolution, position);
        }
        
        // LP claimable is handled separately through getUserLPPosition
        lpClaimable = 0; // Set to 0 as it's calculated via getUserLPPosition
        
        return (borrowerClaimable, lpClaimable);
    }
    
    /**
     * @notice Get key risk parameters for UI display
     */
    function getRiskSummary() external view override returns (
        address supplyAsset,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 reserveFactor
    ) {
        RiskParams memory params = StorageShell.getRiskParams();
        supplyAsset = params.supplyAsset;
        ltv = params.ltv;
        liquidationThreshold = params.liquidationThreshold;
        reserveFactor = params.reserveFactor;
        
        return (supplyAsset, ltv, liquidationThreshold, reserveFactor);
    }
    
    /**
     * @notice Calculate borrowable amount for given collateral
     */
    function calculateBorrowingPower(
        address predictionAsset,
        uint256 collateralAmount
    ) external view override returns (
        uint256 maxBorrowable,
        uint256 collateralValue
    ) {
        if (collateralAmount == 0) return (0, 0);
        
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        MarketData memory market = StorageShell.getMarketData(marketId);
        
        // Get current price in Ray format
        uint256 currentPriceWad = IOracle(params.priceOracle).getCurrentPrice(predictionAsset);
        uint256 currentPriceRay = currentPriceWad.wadToRay();
        
        // Calculate collateral value and max borrow
        collateralValue = CoreMath.calculateCollateralValue(
            collateralAmount,
            currentPriceRay,
            params.supplyAssetDecimals,
            market.collateralAssetDecimals
        );
        
        maxBorrowable = CoreMath.calculateMaxBorrow(collateralValue, params.ltv);
        
        // Check available liquidity
        PoolData memory pool = StorageShell.getPool();
        uint256 availableLiquidity = pool.totalSupplied > pool.totalBorrowedAllMarkets ? 
            pool.totalSupplied - pool.totalBorrowedAllMarkets : 0;
            
        if (maxBorrowable > availableLiquidity) {
            maxBorrowable = availableLiquidity;
        }
        
        return (maxBorrowable, collateralValue);
    }
    
    /**
     * @notice Get user's current LTV ratio
     */
    function getUserLTV(
        address user,
        address predictionAsset
    ) external view override returns (
        uint256 currentLTV,
        uint256 maxLTV
    ) {
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        bytes32 positionId = StorageShell.userPositionId(marketId, user);
        
        // Get updated indices
        (MarketData memory market, PoolData memory pool) = ReserveLogic.getUpdatedMarketIndices(marketId);
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        maxLTV = params.ltv;
        
        if (position.collateralAmount == 0) {
            currentLTV = 0;
            return (currentLTV, maxLTV);
        }
        
        // Get current price
        uint256 currentPriceWad = IOracle(params.priceOracle).getCurrentPrice(predictionAsset);
        uint256 currentPriceRay = currentPriceWad.wadToRay();
        
        // Calculate collateral value
        uint256 collateralValue = CoreMath.calculateCollateralValue(
            position.collateralAmount,
            currentPriceRay,
            params.supplyAssetDecimals,
            market.collateralAssetDecimals
        );
        
        if (collateralValue == 0) {
            currentLTV = 0;
            return (currentLTV, maxLTV);
        }
        
        // Get total debt
        if (position.scaledDebtBalance > 0) {
            uint256 protocolTotalDebt = ILiquidityLayer(params.liquidityLayer)
                .getTotalDebt(params.supplyAsset, address(this));
            (uint256 totalDebt, , ) = getUserDebt(market, pool, position, protocolTotalDebt);
            
            // Calculate LTV (in basis points)
            currentLTV = (totalDebt * 10000) / collateralValue;
        } else {
            currentLTV = 0;
        }
        
        return (currentLTV, maxLTV);
    }
    
    /**
     * @notice Check if position is healthy and can perform actions
     */
    function checkPositionHealth(
        address user,
        address predictionAsset
    ) external view override returns (
        bool isHealthy,
        bool canBorrow,
        bool canWithdrawCollateral
    ) {
        // Get health factor
        uint256 healthFactor = LiquidationLogic.getUserHealthFactor(user, predictionAsset);
        
        isHealthy = healthFactor >= 1e27; // 1.0 in Ray
        
        // Can borrow if healthy and market is active
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        MarketData memory market = StorageShell.getMarketData(marketId);
        
        canBorrow = isHealthy && market.isActive && !market.isMatured;
        
        // Can withdraw collateral only if no debt
        bytes32 positionId = StorageShell.userPositionId(marketId, user);
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        canWithdrawCollateral = position.scaledDebtBalance == 0 && position.collateralAmount > 0;
        
        return (isHealthy, canBorrow, canWithdrawCollateral);
    }
}