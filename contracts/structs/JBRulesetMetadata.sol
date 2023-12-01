// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBGlobalRulesetMetadata} from "./JBGlobalRulesetMetadata.sol";

/// @custom:member global Data used globally in non-migratable ecosystem contracts.
/// @custom:member reservedRate The reserved rate of the ruleset. This number is a percentage calculated out of `JBConstants.MAX_RESERVED_RATE`.
/// @custom:member redemptionRate The redemption rate of the ruleset. This number is a percentage calculated out of `JBConstants.MAX_REDEMPTION_RATE`.
/// @custom:member baseCurrency The currency on which to base the ruleset's weight.
/// @custom:member pausePay A flag indicating if the pay functionality should be paused during the ruleset.
/// @custom:member allowDiscretionaryMinting A flag indicating if the project owner or an operator with the `MINT_TOKENS` permission should be allowed to mint project tokens on demand during this ruleset.
/// @custom:member allowTerminalMigration A flag indicating if migrating terminals should be allowed during this ruleset.
/// @custom:member allowControllerMigration A flag indicating if migrating controllers should be allowed during this ruleset.
/// @custom:member holdFees A flag indicating if fees should be held during this ruleset.
/// @custom:member useTotalSurplusForRedemptions A flag indicating if redemptions should use the project's balance held in all terminals instead of the project's local terminal balance from which the redemption is being fulfilled.
/// @custom:member useDataHookForPay A flag indicating if the data hook should be used for pay transactions during this ruleset.
/// @custom:member useDataHookForRedeem A flag indicating if the data hook should be used for redeem transactions during this ruleset.
/// @custom:member dataHook The data hook to use during this ruleset.
/// @custom:member metadata Metadata of the metadata, up to uint8 in size.
struct JBRulesetMetadata {
    JBGlobalRulesetMetadata global;
    uint256 reservedRate;
    uint256 redemptionRate;
    uint256 baseCurrency;
    bool pausePay;
    bool allowDiscretionaryMinting;
    bool allowTerminalMigration;
    bool allowControllerMigration;
    bool holdFees;
    bool useTotalSurplusForRedemptions;
    bool useDataHookForPay;
    bool useDataHookForRedeem;
    address dataHook;
    uint256 metadata;
}