// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../StorageShell.sol";
import "../DataStruct.sol";
import "../../core/Core.sol";
import "../../interfaces/ILiquidityLayer.sol";
import "../../interfaces/IOracle.sol";
import "../PolynanceEE.sol";
import "./ReserveLogic.sol";

library LiquidationLogic {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    
    bytes32 internal constant ZERO_ID = bytes32(0);
    uint256 internal constant RAY = 1e27;
    
    // ============ Events ============
    event LiquidationCall(
        address indexed collateralAsset,
        address indexed supplyAsset,
        address indexed user,
        uint256 debtToCover,
        uint256 liquidatedCollateralAmount,
        address liquidator
    );
    
    /**
     * @notice Liquidate an undercollateralized position
     * @param liquidator Address performing the liquidation
     * @param user Address being liquidated
     * @param debtToCover Amount of debt to repay (0 means liquidate max allowed)
     * @param predictionAsset The prediction token used as collateral
     * @return actualDebtRepaid Actual amount of debt repaid
     * @return collateralSeized Amount of collateral seized
     */
    function liquidate(
        address liquidator,
        address user,
        uint256 debtToCover,
        address predictionAsset
    ) internal returns (
        uint256 actualDebtRepaid,
        uint256 collateralSeized
    ) {
        // 1. Load current state
        RiskParams memory params = StorageShell.getRiskParams();
        
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        bytes32 positionId = StorageShell.userPositionId(marketId, user);
        
        // 2. Update market indices and get updated state
        (MarketData memory market, PoolData memory pool) = ReserveLogic.updateAndStoreMarketIndices(marketId);
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        // 3. Basic validation
        if (!market.isActive) revert PolynanceEE.MarketNotActive();
        if (position.scaledDebtBalance == 0) revert PolynanceEE.NoDebtToRepay();
        
        // 4. Get oracle price in Ray format
        uint256 currentPriceWad = IOracle(params.priceOracle).getCurrentPrice(predictionAsset);
        uint256 currentPriceRay = currentPriceWad.wadToRay();
        
        // 5. Get protocol total debt from Aave
        uint256 protocolTotalDebt = ILiquidityLayer(params.liquidityLayer)
            .getTotalDebt(params.supplyAsset, address(this));
        
        // 6. Create Core input
        CoreLiquidationInput memory input = CoreLiquidationInput({
            repayAmount: debtToCover,
            collateralPrice: currentPriceRay,
            protocolTotalDebt: protocolTotalDebt
        });
        
        // 7. Call Core (handles all validation and calculations)
        (
            MarketData memory newMarket,
            PoolData memory newPool,
            UserPosition memory newPosition,
            CoreLiquidationOutput memory output
        ) = Core(address(this)).processLiquidation(market, pool, position, input, params);
        
        actualDebtRepaid = output.actualRepayAmount;
        collateralSeized = output.collateralSeized;
        
        // 8. Store updated state
        StorageShell.next(DataType.MARKET_DATA, abi.encode(newMarket), marketId);
        StorageShell.next(DataType.POOL_DATA, abi.encode(newPool), ZERO_ID);
        StorageShell.next(DataType.USER_POSITION, abi.encode(newPosition), positionId);
        
        // 9. Execute side effects
        // Transfer repay amount from liquidator
        IERC20(params.supplyAsset).safeTransferFrom(liquidator, address(this), actualDebtRepaid);
        
        // Repay to Aave (Core provides the exact amount)
        if (output.liquidityRepayAmount > 0) {
            ILiquidityLayer(params.liquidityLayer).repay(
                params.supplyAsset,
                output.liquidityRepayAmount,
                InterestRateMode.VARIABLE,
                address(this)
            );
        }
        
        // Transfer seized collateral to liquidator
        IERC20(predictionAsset).safeTransfer(liquidator, collateralSeized);
        
        emit LiquidationCall(
            predictionAsset,
            params.supplyAsset,
            user,
            actualDebtRepaid,
            collateralSeized,
            liquidator
        );
        
        return (actualDebtRepaid, collateralSeized);
    }
    
    /**
     * @notice Get user's current health factor
     * @param user Address of the user
     * @param predictionAsset The prediction token used as collateral
     * @return healthFactor The user's health factor (1e27 = 1.0)
     */
    function getUserHealthFactor(
        address user,
        address predictionAsset
    ) internal view returns (uint256 healthFactor) {
        // Load state
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        bytes32 positionId = StorageShell.userPositionId(marketId, user);
        
        MarketData memory market = StorageShell.getMarketData(marketId);
        PoolData memory pool = StorageShell.getPool();
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        if (position.scaledDebtBalance == 0) {
            return type(uint256).max;
        }
        
        // Get oracle price in Ray format
        uint256 currentPriceWad = IOracle(params.priceOracle).getCurrentPrice(predictionAsset);
        uint256 currentPriceRay = currentPriceWad.wadToRay();
        
        // Get protocol debt
        uint256 protocolTotalDebt = ILiquidityLayer(params.liquidityLayer)
            .getTotalDebt(params.supplyAsset, address(this));
        
        return Core(address(this)).getUserHealthFactor(
            market,
            pool,
            position,
            currentPriceRay,
            protocolTotalDebt,
            params
        );
    }
    
    /**
     * @notice Check if a position is liquidatable
     * @param user Address of the user
     * @param predictionAsset The prediction token used as collateral
     * @return True if the position can be liquidated
     */
    function isUserLiquidatable(
        address user,
        address predictionAsset
    ) internal view returns (bool) {
        uint256 healthFactor = getUserHealthFactor(user, predictionAsset);
        return healthFactor < RAY;
    }
}