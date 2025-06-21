// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../StorageShell.sol";
import "../DataStruct.sol";
import "../../core/Core.sol";
import "../../core/CoreMath.sol";
import "../../interfaces/ILiquidityLayer.sol";
import "../../interfaces/IOracle.sol";
import "../PolynanceEE.sol";
import "./ReserveLogic.sol";

library BorrowLogic {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    
    bytes32 internal constant ZERO_ID = bytes32(0);
    
    // ============ Events ============
    event Borrow(
        address indexed user,
        address indexed predictionAsset,
        uint256 collateralAmount,
        uint256 borrowAmount,
        uint256 totalCollateral,
        uint256 totalBorrow
    );
    
    event Repay(
        address indexed user,
        address indexed predictionAsset,
        uint256 repayAmount,
        uint256 collateralReturned,
        uint256 totalCollateral,
        uint256 totalBorrow
    );
    
    /**
     * @notice Deposit collateral and/or borrow against collateral
     * @param borrower Address of the borrower
     * @param collateralAmount Amount of prediction tokens to deposit (can be 0)
     * @param borrowAmount Amount to borrow (0 means borrow max)
     * @param predictionAsset Address of the prediction token
     * @return actualBorrowAmount Amount actually borrowed
     */
    function borrow(
        address borrower,
        uint256 collateralAmount,
        uint256 borrowAmount,
        address predictionAsset
    ) internal returns (uint256 actualBorrowAmount) {
        // 1. Load current state
        RiskParams memory params = StorageShell.getRiskParams();
        
        if (collateralAmount == 0 && borrowAmount == 0) revert PolynanceEE.InvalidAmount();
        
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        bytes32 positionId = StorageShell.userPositionId(marketId, borrower);
        
        // 2. Update market indices and get updated state
        (MarketData memory market, PoolData memory pool) = ReserveLogic.updateAndStoreMarketIndices(marketId);
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        // Check if position exists but trying to borrow without collateral
        if (collateralAmount == 0 && position.collateralAmount == 0 && borrowAmount > 0) {
            revert PolynanceEE.InsufficientCollateral();
        }
        
        // 3. Get oracle price in Ray format
        uint256 currentPriceWad = IOracle(params.priceOracle).getCurrentPrice(predictionAsset);
        uint256 currentPriceRay = currentPriceWad.wadToRay();
        
        // 4. Get protocol total debt from Aave
        uint256 protocolTotalDebt = ILiquidityLayer(params.liquidityLayer)
            .getTotalDebt(params.supplyAsset, address(this));
        
        // 5. Create Core input with price in Ray
        CoreBorrowInput memory input = CoreBorrowInput({
            borrowAmount: borrowAmount,
            collateralAmount: collateralAmount,
            collateralPrice: currentPriceRay,  // Ray format
            protocolTotalDebt: protocolTotalDebt
        });
        
        // 6. Call Core with updated market and pool data
        Core core = Core(address(this));
        (
            MarketData memory newMarket,
            PoolData memory newPool,
            UserPosition memory newPosition,
            CoreBorrowOutput memory output
        ) = core.processBorrow(market, pool, position, input, params);
        
        actualBorrowAmount = output.actualBorrowAmount;
        
        // 7. Store ALL updated state
        StorageShell.next(DataType.MARKET_DATA, abi.encode(newMarket), marketId);
        StorageShell.next(DataType.POOL_DATA, abi.encode(newPool), ZERO_ID);
        StorageShell.next(DataType.USER_POSITION, abi.encode(newPosition), positionId);
        
        // 8. Execute side effects
        // Transfer collateral from user
        if (collateralAmount > 0) {
            IERC20(predictionAsset).safeTransferFrom(borrower, address(this), collateralAmount);
        }
        
        // Borrow from Aave and transfer to user
        if (actualBorrowAmount > 0) {
            ILiquidityLayer(params.liquidityLayer).borrow(
                params.supplyAsset, 
                actualBorrowAmount, 
                InterestRateMode.VARIABLE, // Assuming VARIABLE borrow rate
                address(this)
            );
            IERC20(params.supplyAsset).safeTransfer(borrower, actualBorrowAmount);
        }
        
        emit Borrow(
            borrower,
            predictionAsset,
            collateralAmount,
            actualBorrowAmount,
            newPosition.collateralAmount,
            newPosition.borrowAmount
        );
        
        return actualBorrowAmount;
    }
    
    /**
     * @notice Repay borrowed amount and retrieve collateral
     * @param borrower Address of the borrower
     * @param repayAmount Amount to repay (0 means repay all)
     * @param predictionAsset Address of the prediction token
     * @return actualRepayAmount Amount actually repaid
     */
    function repay(
        address borrower,
        uint256 repayAmount,
        address predictionAsset
    ) internal returns (uint256 actualRepayAmount) {
        // 1. Load current state
        RiskParams memory params = StorageShell.getRiskParams();
        Core core = Core(address(this));
        
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        bytes32 positionId = StorageShell.userPositionId(marketId, borrower);
        
        // 2. Update market indices and get updated state
        (MarketData memory market, PoolData memory pool) = ReserveLogic.updateAndStoreMarketIndices(marketId);
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        if (position.scaledDebtBalance == 0) revert PolynanceEE.NoDebtToRepay();
        
        // 3. Get protocol total debt from Aave
        uint256 protocolTotalDebt = ILiquidityLayer(params.liquidityLayer)
            .getTotalDebt(params.supplyAsset, address(this));
        
        // 4. If repayAmount is 0, calculate total debt to repay all
        if (repayAmount == 0) {
            (repayAmount, , ) = core.getUserDebt(market, pool, position, protocolTotalDebt);
        }
        
        // 5. Create Core input
        CoreRepayInput memory input = CoreRepayInput({
            repayAmount: repayAmount,
            protocolTotalDebt: protocolTotalDebt
        });
        
        // 6. Call Core
        (
            MarketData memory newMarket,
            PoolData memory newPool,
            UserPosition memory newPosition,
            CoreRepayOutput memory output
        ) = core.processRepay(market, pool, position, input);
        
        actualRepayAmount = output.actualRepayAmount;
        
        // 7. Store updated state
        StorageShell.next(DataType.MARKET_DATA, abi.encode(newMarket), marketId);
        StorageShell.next(DataType.POOL_DATA, abi.encode(newPool), ZERO_ID);
        StorageShell.next(DataType.USER_POSITION, abi.encode(newPosition), positionId);
        
        // 8. Execute side effects
        // Transfer repay amount from user
        IERC20(params.supplyAsset).safeTransferFrom(borrower, address(this), output.totalDebt);
        
        // Repay to Aave (only the liquidity portion)
        if (output.liquidityRepayAmount > 0) {
            ILiquidityLayer(params.liquidityLayer).repay(
                params.supplyAsset,
                output.liquidityRepayAmount,
                InterestRateMode.VARIABLE, // Assuming VARIABLE borrow rate
                address(this)
            );
        }
        
        // Return collateral to user
        if (output.collateralToReturn > 0) {
            IERC20(predictionAsset).safeTransfer(borrower, output.collateralToReturn);
        }
        
        emit Repay(
            borrower,
            predictionAsset,
            actualRepayAmount,
            output.collateralToReturn,
            newPosition.collateralAmount,
            newPosition.borrowAmount
        );
        
        return actualRepayAmount;
    }
    
    /**
     * @notice Get the maximum amount a user can borrow based on their collateral
     * @param user Address of the user
     * @param predictionAsset Address of the prediction token
     * @return maxBorrowable Maximum amount user can borrow
     * @return healthFactor Current health factor (1e27 = 1.0)
     */
    function getBorrowingCapacity(
        address user,
        address predictionAsset
    ) internal view returns (uint256 maxBorrowable, uint256 healthFactor) {
        // Load state
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        bytes32 positionId = StorageShell.userPositionId(marketId, user);
        
        MarketData memory market = StorageShell.getMarketData(marketId);
        PoolData memory pool = StorageShell.getPool();
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        if (position.collateralAmount == 0) {
            return (0, type(uint256).max);
        }
        
        // Get current price in Ray format
        uint256 currentPriceWad = IOracle(params.priceOracle).getCurrentPrice(predictionAsset);
        uint256 currentPriceRay = currentPriceWad.wadToRay();
        
        // Calculate max borrowable using Core
        uint256 collateralValue = CoreMath.calculateCollateralValue(
            position.collateralAmount,
            currentPriceRay,  // Ray format
            params.supplyAssetDecimals,
            market.collateralAssetDecimals
        );
        
        maxBorrowable = CoreMath.calculateMaxBorrow(collateralValue, params.ltv);
        
        // Calculate health factor if user has debt
        if (position.scaledDebtBalance > 0) {
            uint256 protocolTotalDebt = ILiquidityLayer(params.liquidityLayer)
                .getTotalDebt(params.supplyAsset, address(this));
                
            Core core = Core(address(this));
            healthFactor = core.getUserHealthFactor(
                market,
                pool,
                position,
                currentPriceRay,  // Ray format
                protocolTotalDebt,
                params
            );
        } else {
            healthFactor = type(uint256).max;
        }
        
        return (maxBorrowable, healthFactor);
    }
}