// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "../StorageShell.sol";
import "../DataStruct.sol";
import "../../core/Core.sol";
import "../../interfaces/ILiquidityLayer.sol";
import "../../interfaces/IOracle.sol";
import "../../interfaces/IPositionToken.sol";
import "../PolynanceEE.sol";
import "./ReserveLogic.sol";

library MarketResolveLogic {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;
    using Math for uint256;
    
    bytes32 internal constant ZERO_ID = bytes32(0);
    
    // ============ Events ============
    event MarketResolved(
        bytes32 indexed marketId,
        uint256 finalCollateralPrice,
        uint256 totalCollateralRedeemed,
        uint256 liquidityRepaid
    );
    
    event BorrowerPositionRedeemed(
        address indexed borrower,
        uint256 collateralAmount,
        uint256 rebateAmount
    );
    
    event LPPositionRedeemed(
        address indexed lpHolder,
        uint256 lpTokensBurned,
        uint256 totalPayout
    );
    
    event ProtocolRevenuesClaimed(
        address indexed treasury,
        uint256 amount
    );
    
    /**
     * @notice Resolve a prediction market
     * @param resolver Address attempting to resolve (must be curator)
     * @param predictionAsset The prediction token being resolved
     */
    function resolve(
        address resolver,
        address predictionAsset
    ) internal {
        // 1. Load state
        RiskParams memory params = StorageShell.getRiskParams();
        
        if (resolver != params.curator) revert PolynanceEE.NotCurator();
        
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        
        // 2. Update market indices and get updated state
        (MarketData memory market, PoolData memory pool) = ReserveLogic.updateAndStoreMarketIndices(marketId);
        ResolutionData memory resolution = StorageShell.getResolutionData(marketId);
        
        if (resolution.isMarketResolved) revert PolynanceEE.MarketAlreadyResolved();
        if (!market.isActive) revert PolynanceEE.MarketNotActive();
        
        // 3. Redeem all collateral
        uint256 balanceBefore = IERC20(params.supplyAsset).balanceOf(address(this));
        IPositionToken(predictionAsset).redeem();
        uint256 balanceAfter = IERC20(params.supplyAsset).balanceOf(address(this));
        uint256 totalCollateralRedeemed = balanceAfter - balanceBefore;
        
        // 4. Get current Aave debt
        uint256 liquidityLayerDebt = ILiquidityLayer(params.liquidityLayer)
            .getDebtBalance(params.supplyAsset, address(this), InterestRateMode.VARIABLE);
        
        // 5. Create Core input
        CoreResolutionInput memory input = CoreResolutionInput({
            totalCollateralRedeemed: totalCollateralRedeemed,
            liquidityLayerDebt: liquidityLayerDebt
        });
        
        // 6. Call Core to calculate distributions
        Core core = Core(address(this));
        (
            MarketData memory newMarket,
            PoolData memory newPool,
            ResolutionData memory newResolution
        ) = core.processResolution(market, pool, resolution, input, params);
        
        // 7. Store updated state
        StorageShell.next(DataType.MARKET_DATA, abi.encode(newMarket), marketId);
        StorageShell.next(DataType.POOL_DATA, abi.encode(newPool), ZERO_ID);
        StorageShell.next(DataType.RESOLUTION_DATA, abi.encode(newResolution), marketId);
        
        // 8. Repay Aave debt
        if (newResolution.liquidityRepaid > 0) {
            ILiquidityLayer(params.liquidityLayer).repay(
                params.supplyAsset,
                newResolution.liquidityRepaid,
                InterestRateMode.VARIABLE,
                address(this)
            );
        }
        
        // 9. Get final price for event
        uint256 finalPrice = IOracle(params.priceOracle).getCurrentPrice(predictionAsset);
        
        emit MarketResolved(
            marketId,
            finalPrice,
            totalCollateralRedeemed,
            newResolution.liquidityRepaid
        );
    }
    
    /**
     * @notice Claim borrower's rebate after resolution
     * @param borrower Address of the borrower
     * @param predictionAsset The prediction token
     * @return rebateAmount Amount of rebate claimed
     */
    function claimBorrowerPosition(
        address borrower,
        address predictionAsset
    ) internal returns (uint256 rebateAmount) {
        // 1. Load state
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        bytes32 positionId = StorageShell.userPositionId(marketId, borrower);
        
        ResolutionData memory resolution = StorageShell.getResolutionData(marketId);
        MarketData memory market = StorageShell.getMarketData(marketId);
        UserPosition memory position = StorageShell.getUserPosition(positionId);
        
        if (!resolution.isMarketResolved) revert PolynanceEE.MarketNotResolved();
        if (position.collateralAmount == 0) revert PolynanceEE.NoPositionToRedeem();
        
        // 2. Calculate rebate: (user collateral / total collateral) * borrower pool
        rebateAmount = 0;
        if (market.totalCollateral > 0 && resolution.borrowerPool > 0) {
            rebateAmount = resolution.borrowerPool.mulDiv(
                position.collateralAmount,
                market.totalCollateral
            );
        }
        
        // 3. Clear position
        UserPosition memory clearedPosition;
        StorageShell.next(DataType.USER_POSITION, abi.encode(clearedPosition), positionId);
        
        // 4. Transfer rebate if any
        if (rebateAmount > 0) {
            IERC20(params.supplyAsset).safeTransfer(borrower, rebateAmount);
        }
        
        emit BorrowerPositionRedeemed(borrower, position.collateralAmount, rebateAmount);
        
        return rebateAmount;
    }
    
    /**
     * @notice Claim LP position after resolution
     * @param lpHolder Address of the LP token holder
     * @param lpTokenAmount Amount of LP tokens to redeem
     * @param totalSupply Current total supply of LP tokens
     * @return totalPayout Total amount paid to LP
     */
    function claimLPPosition(
        address lpHolder,
        uint256 lpTokenAmount,
        uint256 totalSupply
    ) internal returns (uint256 totalPayout) {
        // 1. Load state
        RiskParams memory params = StorageShell.getRiskParams();
        PoolData memory pool = StorageShell.getPool();
        
        // Note: In V2, resolution is pool-wide, not per market
        bytes32 resolutionId = ZERO_ID; // Pool-wide resolution
        ResolutionData memory resolution = StorageShell.getResolutionData(resolutionId);
        
        if (!resolution.isMarketResolved) revert PolynanceEE.MarketNotResolved();
        if (lpTokenAmount == 0) revert PolynanceEE.InvalidAmount();
        if (totalSupply == 0) revert PolynanceEE.InvalidAmount();
        
        // 2. Calculate LP's share of the LP pool
        uint256 lpPoolShare = 0;
        if (resolution.lpPool > 0) {
            lpPoolShare = resolution.lpPool.mulDiv(
                lpTokenAmount,
                totalSupply
            );
        }

        // 4. Withdraw from Aave if needed
        uint256 balanceOfBefore = IERC20(params.supplyAsset).balanceOf(address(this));
        ILiquidityLayer(params.liquidityLayer).withdraw(
            params.supplyAsset,
            IERC20(address(this)).balanceOf(lpHolder),
            address(this)
        );
        uint256 balanceOfAfter = IERC20(params.supplyAsset).balanceOf(address(this));
        uint256 payout = balanceOfAfter - balanceOfBefore;
        
        // 5. Calculate total payout
        totalPayout = lpPoolShare + payout;
        
        // 6. Transfer total payout to LP holder
        if (totalPayout > 0) {
            IERC20(params.supplyAsset).safeTransfer(lpHolder, totalPayout);
        }
        
        // 7. Update pool state
        PoolData memory newPool = pool;
        newPool.totalSupplied -= lpTokenAmount;
        StorageShell.next(DataType.POOL_DATA, abi.encode(newPool), ZERO_ID);
        
        emit LPPositionRedeemed(lpHolder, lpTokenAmount, totalPayout);
        
        // Note: LP token burning should be handled by the main contract
        return totalPayout;
    }
    
    /**
     * @notice Claim protocol revenues after resolution
     * @param treasury Address to receive protocol revenues
     * @return protocolAmount Amount claimed
     */
    function claimProtocolRevenue(
        address treasury
    ) internal returns (uint256 protocolAmount) {
        // 1. Load state
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 resolutionId = ZERO_ID; // Pool-wide resolution
        ResolutionData memory resolution = StorageShell.getResolutionData(resolutionId);
        
        if (!resolution.isMarketResolved) revert PolynanceEE.MarketNotResolved();
        // if (resolution.protocolClaimed) revert PolynanceEE.AlreadyClaimed();
        
        protocolAmount = resolution.protocolPool;
        
        if (protocolAmount > 0) {
            // 2. Mark as claimed
            resolution.protocolClaimed = true;
            StorageShell.next(DataType.RESOLUTION_DATA, abi.encode(resolution), resolutionId);
            // 3. Transfer to treasury
            IERC20(params.supplyAsset).safeTransfer(treasury, protocolAmount);
            emit ProtocolRevenuesClaimed(treasury, protocolAmount);
        }
        
        return protocolAmount;
    }
    
    /**
     * @notice Check if a market is resolved
     * @param predictionAsset The prediction token
     * @return isResolved True if market is resolved
     */
    function isMarketResolved(
        address predictionAsset
    ) internal view returns (bool isResolved) {
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        ResolutionData memory resolution = StorageShell.getResolutionData(marketId);
        return resolution.isMarketResolved;
    }
    
    /**
     * @notice Get resolution data for a market
     * @param predictionAsset The prediction token
     * @return resolution Resolution data
     */
    function getResolutionData(
        address predictionAsset
    ) internal view returns (ResolutionData memory resolution) {
        RiskParams memory params = StorageShell.getRiskParams();
        bytes32 marketId = StorageShell.reserveId(params.supplyAsset, predictionAsset);
        return StorageShell.getResolutionData(marketId);
    }
}