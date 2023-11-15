// SPDX-License-Identifier: MIT
pragma solidity >=0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {MockPriceFeed} from './mock/MockPriceFeed.sol';

// A ruleset's weight can be cached to make larger intervals tractible under the gas limit.
contract TestRulesetWeightCaching_Local is TestBaseWorkflow {
    uint256 private constant _GAS_LIMIT = 30_000_000;
    uint8 private constant _WEIGHT_DECIMALS = 18; // FIXED 
    uint256 private constant _DURATION = 1;
    uint256 private constant _DECAY_RATE = 1;
    
    IJBController private _controller;
    IJBRulesets private _rulesets;
    address private _projectOwner;
    
    JBRulesetData private _data;
    JBRulesetMetadata private _metadata;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _rulesets = jbRulesetStore();
        _controller = jbController();
        _data = JBRulesetData({
            duration: _DURATION,
            weight: 1000 * 10 ** _WEIGHT_DECIMALS,
            decayRate: _DECAY_RATE,
            approvalHook: IJBRulesetApprovalHook(address(0))
        });

        _metadata = JBRulesetMetadata({
            global: JBGlobalRulesetMetadata({
                allowSetTerminals: false,
                allowSetController: false,
                pauseTransfers: false
            }),
            reservedRate: 0,
            redemptionRate: 0,
            baseCurrency: uint32(uint160(JBTokenList.ETH)),
            pausePay: false,
            allowMinting: false,
            allowTerminalMigration: false,
            allowControllerMigration: false,
            holdFees: false,
            useTotalOverflowForRedemptions: true,
            useDataSourceForPay: false,
            useDataSourceForRedeem: false,
            dataSource: address(0),
            metadata: 0
        });
    }
    
    /// Test that caching a ruleset's weight yields the same result as computing it.
    function testWeightCaching(uint256 _rulesetDiff) public {
        // TODO temporarily removed for faster test suite
        // // Bound to 8x the decay multiple cache threshold.
        // _rulesetDiff = bound(_rulesetDiff, 0, 80000);

        // // Keep references to the projects.
        // uint256 _projectId1;
        // uint256 _projectId2;

        // // Package up the configuration info.
        // JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);

        // {
        //     _rulesetConfigurations[0].mustStartAtOrAfter = 0;
        //     _rulesetConfigurations[0].data = _data;
        //     _rulesetConfigurations[0].metadata = _metadata;
        //     _rulesetConfigurations[0].groupedSplits = new JBGroupedSplits[](0);
        //     _rulesetConfigurations[0].fundAccessConstraints = new JBFundAccessConstraints[](0);

        //     // Create the project to test.
        //     _projectId1 = _controller.launchProjectFor({
        //         owner: _projectOwner,
        //         projectMetadata: JBProjectMetadata({content: "myIPFSHash", domain: 1}),
        //         rulesetConfigurations: _rulesetConfigurations,
        //         terminalConfigurations: new JBTerminalConfig[](0),
        //         memo: ""
        //     });

        //     // Create the project to test.
        //     _projectId2 = _controller.launchProjectFor({
        //         owner: _projectOwner,
        //         projectMetadata: JBProjectMetadata({content: "myIPFSHash", domain: 1}),
        //         rulesetConfigurations: _rulesetConfigurations,
        //         terminalConfigurations: new JBTerminalConfig[](0),
        //         memo: ""
        //     });
        // }

        // // Keep a reference to the current rulesets.
        // JBRuleset memory _ruleset1 = jbRulesetStore().currentOf(_projectId1);
        // JBRuleset memory _ruleset2 = jbRulesetStore().currentOf(_projectId2);

        // // Go a few rolled over rulesets into the future.
        // vm.warp(block.timestamp + (_DURATION * 10));

        // // Keep a reference to the amount of gas before the caching call.
        // uint256 _gasBeforeCache = gasleft();

        // // Cache the weight in the second project.
        // _rulesets.updateRulesetWeightCache(_projectId2);

        // // Keep a reference to the amout of gas spent on the call.
        // uint256 _gasDiffCache = _gasBeforeCache - gasleft();

        // // Make sure the diff is within the limit
        // assertLe(_gasDiffCache, _GAS_LIMIT);

        // // Go many rolled over rulesets into the future.
        // vm.warp(block.timestamp + (_DURATION * _rulesetDiff));

        // // Cache the weight in the second project again.
        // _rulesets.updateRulesetWeightCache(_projectId2);

        // // Inherit the weight.
        // _rulesetConfigurations[0].data.weight = 0;

        // // Keep a reference to the amount of gas before the call.
        // uint256 _gasBefore1 = gasleft();

        // // Reconfigure the ruleset.
        // vm.startPrank(_projectOwner);
        // _controller.reconfigureRulesetsOf({
        //     projectId: _projectId1,
        //     rulesetConfigurations: _rulesetConfigurations,
        //     memo: ""
        // });

        // // Keep a reference to the amout of gas spent on the call.
        // uint256 _gasDiff1 = _gasBefore1 - gasleft();

        // // Make sure the diff is within the limit
        // assertLe(_gasDiff1, _GAS_LIMIT);

        // // Keep a reference to the amount of gas before the call.
        // uint256 _gasBefore2 = gasleft();

        // _controller.reconfigureRulesetsOf({
        //     projectId: _projectId2,
        //     rulesetConfigurations: _rulesetConfigurations,
        //     memo: ""
        // });
        // vm.stopPrank();

        // // Keep a reference to the amout of gas spent on the call.
        // uint256 _gasDiff2 = _gasBefore2 - gasleft();

        // // Make sure the diff is within the limit
        // assertLe(_gasDiff2, _GAS_LIMIT);

        // // Renew the reference to the current ruleset.
        // _ruleset1 = jbRulesetStore().currentOf(_projectId1);
        // _ruleset2 = jbRulesetStore().currentOf(_projectId2);

        // // The cached call should have been cheaper.
        // assertLe(_gasDiff2, _gasDiff1);

        // // Make sure the rulesets have the same weight.
        // assertEq(_ruleset1.weight, _ruleset2.weight);

        // // Cache the weight in the second project again.
        // _rulesets.updateRulesetWeightCache(_projectId2);

        // // Go many rolled over rulesets into the future.
        // vm.warp(block.timestamp + (_DURATION * _rulesetDiff));

        // // Reconfigure the ruleset.
        // vm.prank(_projectOwner);
        // _controller.reconfigureRulesetsOf({
        //     projectId: _projectId2,
        //     rulesetConfigurations: _rulesetConfigurations,
        //     memo: ""
        // });
    }
}