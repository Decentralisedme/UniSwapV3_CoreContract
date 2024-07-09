// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Position {
    // info stored for each user's position
    struct Info {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // the fees owed to the position owner in token0/token1
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /// @notice Returns the Info struct of a position, given an owner and position boundaries
    /// @param self The mapping containing all user positions
    /// @param owner The address of the position owner
    /// @param tickLower The lower tick boundary of the position
    /// @param tickUpper The upper tick boundary of the position
    /// @return position The position info struct of the given owners' position
    function get(mapping(bytes32 => Info) storage self, address owner, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (Info storage position)
    {
        // Positin is a mapping of keccak of owner/tickLower/Upper
        position = self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 FeeGrowthInside0X128,
        uint256 FeeGrowthInside1X128
    ) internal {
        // 1- fist thing will upadate Info sotage: to make more gas efficinet pass Info to memory
        Info memory _self = self;

        if (liquidityDelta == 0) {
            // disallow pokes for 0 liquidity positions
            require(_self.liquidity > 0, "0 liquidity");
        }
        if (liquidityDelta != 0) {
            // u
            self.liquidity = liquidityDelta < 0
                // liquidity is uint128, we need to deal with negtive liquidity delta
                ? _self.liquidity - uint128(-liquidityDelta)
                : _self.liquidity + uint128(liquidityDelta);
        }
    }
}
