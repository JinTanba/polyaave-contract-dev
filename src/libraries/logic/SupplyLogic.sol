// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../StorageShell.sol";
import "../DataStruct.sol";
import "../../core/Core.sol";
import "../../interfaces/ILiquidityLayer.sol";
import "../PolynanceEE.sol";
import "./ReserveLogic.sol";

library SupplyLogic {
    using SafeERC20 for IERC20;
    
    bytes32 internal constant ZERO_ID = bytes32(0);
    
    // ============ Events ============
    event Supply(
        address indexed supplier,
        uint256 amount,
        uint256 lpTokensMinted
    );
    
    event MarketIndicesUpdated(
        bytes32 indexed marketId,
        uint256 borrowIndex,
        uint256 accumulatedSpread
    );
    
    /**
     * @notice Supply liquidity to the pool
     * @param supplier Address supplying liquidity
     * @param amount Amount of supply asset to deposit
     * @param currentLPBalance Current LP token balance of the supplier
     * @param activeMarkets Array of active market IDs to update indices for
     * @return lpTokensMinted Amount of LP tokens to mint
     */
    function supply(
        address supplier,
        uint256 amount,
        uint256 currentLPBalance,
        bytes32[] memory activeMarkets
    ) internal returns (uint256 lpTokensMinted) {
        // 1. Load current state
        RiskParams memory params = StorageShell.getRiskParams();
        
        // 2. Validate
        if (amount == 0) revert PolynanceEE.InvalidAmount();
        
        // 3. Update indices for all active markets to ensure spread is current
        PoolData memory pool = ReserveLogic.updateMultipleMarketIndices(activeMarkets);
        
        // 4. Create Core input
        CoreSupplyInput memory input = CoreSupplyInput({
            userLPBalance: currentLPBalance,
            supplyAmount: amount
        });
        
        // 5. Call Core with updated pool state
        (
            PoolData memory newPool,
            CoreSupplyOutput memory output
        ) = Core(address(this)).processSupply(pool, input);
        
        lpTokensMinted = output.lpTokensToMint;
        
        // 6. Store updated pool state
        StorageShell.next(DataType.POOL_DATA, abi.encode(newPool), ZERO_ID);
        
        // 7. Execute side effects
        // Transfer supply asset from supplier
        IERC20(params.supplyAsset).safeTransferFrom(supplier, address(this), amount);
        
        // Supply to Aave
        ILiquidityLayer(params.liquidityLayer).supply(
            params.supplyAsset,
            amount,
            address(this)
        );
        
        emit Supply(supplier, amount, lpTokensMinted);
        
        // Note: LP token minting is handled by the main contract (ERC20 mint)
        return lpTokensMinted;
    }
    

}