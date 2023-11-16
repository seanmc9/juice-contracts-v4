// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import {JBCurrencies} from "@juicebox/libraries/JBCurrencies.sol";
import {JBConstants} from "@juicebox/libraries/JBConstants.sol";
import {JBTokens} from "@juicebox/libraries/JBTokens.sol";
import {JBSplitsGroups} from "@juicebox/libraries/JBSplitsGroups.sol";

contract AccessJBLib {
    function ETH() external pure returns (uint256) {
        return JBCurrencies.ETH;
    }

    function USD() external pure returns (uint256) {
        return JBCurrencies.USD;
    }

    function ETHToken() external pure returns (address) {
        return JBTokens.ETH;
    }

    function MAX_FEE() external pure returns (uint256) {
        return JBConstants.MAX_FEE;
    }

    function MAX_RESERVED_RATE() external pure returns (uint256) {
        return JBConstants.MAX_RESERVED_RATE;
    }

    function MAX_REDEMPTION_RATE() external pure returns (uint256) {
        return JBConstants.MAX_REDEMPTION_RATE;
    }

    function MAX_DISCOUNT_RATE() external pure returns (uint256) {
        return JBConstants.MAX_DISCOUNT_RATE;
    }

    function SPLITS_TOTAL_PERCENT() external pure returns (uint256) {
        return JBConstants.SPLITS_TOTAL_PERCENT;
    }
}
