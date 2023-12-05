// SPDX-License-Identifier: MIT
pragma solidity >=0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {MockPriceFeed} from "./mock/MockPriceFeed.sol";

/// Funds can be accessed in three ways:
/// 1. project owners set a payout limit to prioritize spending to pre-determined destinations. funds being removed from the protocol incurs fees unless the recipients are feeless addresses.
/// 2. project owners set a surplus payout limit to allow spending funds from the project's surplus balance in the terminal (i.e. the balance in excess of their payout limit). incurs fees unless the caller is a feeless address.
/// 3. token holders can redeem tokens to access surplus funds. incurs fees if the redemption rate != 100%, unless the beneficiary is a feeless address.
/// Each of these only incurs protocol fees if the `_FEE_PROJECT_ID` (project with ID #1) accepts the token being accessed.
contract TestAccessToFunds_Local is TestBaseWorkflow {
    uint256 private constant _FEE_PROJECT_ID = 1;
    uint8 private constant _WEIGHT_DECIMALS = 18; // FIXED
    uint8 private constant _NATIVE_DECIMALS = 18; // FIXED
    uint8 private constant _PRICE_FEED_DECIMALS = 10;
    uint256 private constant _USD_PRICE_PER_NATIVE = 2000 * 10 ** _PRICE_FEED_DECIMALS; // 2000 USDC == 1 native token

    IJBController private _controller;
    IJBPrices private _prices;
    IJBMultiTerminal private _terminal;
    IJBMultiTerminal private _terminal2;
    IJBTokens private _tokens;
    address private _projectOwner;
    address private _beneficiary;
    MockERC20 private _usdcToken;
    uint256 private _projectId;

    JBRulesetData private _data;
    JBRulesetMetadata private _metadata;

    function setUp() public override {
        super.setUp();

        _projectOwner = multisig();
        _beneficiary = beneficiary();
        _usdcToken = usdcToken();
        _tokens = jbTokens();
        _controller = jbController();
        _prices = jbPrices();
        _terminal = jbMultiTerminal();
        _terminal2 = jbMultiTerminal2();
        _data = JBRulesetData({
            duration: 0,
            weight: 1000 * 10 ** _WEIGHT_DECIMALS,
            decayRate: 0,
            approvalHook: IJBRulesetApprovalHook(address(0))
        });

        _metadata = JBRulesetMetadata({
            reservedRate: JBConstants.MAX_RESERVED_RATE / 2, //50%
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE / 2, //50%
            baseCurrency: uint32(uint160(JBTokenList.NATIVE)),
            pausePay: false,
            pauseCreditTransfers: false,
            allowDiscretionaryMinting: false,
            allowTerminalMigration: false,
            allowSetTerminals: false,
            allowControllerMigration: false,
            allowSetController: false,
            holdFees: false,
            useTotalSurplusForRedemptions: true,
            useDataHookForPay: false,
            useDataHookForRedeem: false,
            dataHook: address(0),
            metadata: 0
        });
    }

    // Tests that basic payout limit and surplus payout limits work as intended.
    function testNativePayoutLimits() public {
        // Hardcode values to use.
        uint256 _nativeCurrencyPayoutLimit = 10 * 10 ** _NATIVE_DECIMALS;
        uint256 _nativeCurrencySurplusPayoutLimit = 5 * 10 ** _NATIVE_DECIMALS;

        // Package up the limits for the given terminal.
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        {
            // Specify a payout limit.
            JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](1);
            _payoutLimits[0] = JBCurrencyAmount({
                amount: _nativeCurrencyPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });

            // Specify a surplus payout limit.
            JBCurrencyAmount[] memory _surplusPayoutLimits = new JBCurrencyAmount[](1);
            _surplusPayoutLimits[0] = JBCurrencyAmount({
                amount: _nativeCurrencySurplusPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });

            _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
                terminal: address(_terminal),
                token: JBTokenList.NATIVE,
                payoutLimits: _payoutLimits,
                surplusPayoutLimits: _surplusPayoutLimits
            });
        }

        {
            // Package up the ruleset configuration.
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].data = _data;
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            JBAccountingContextConfig[] memory _accountingContextConfigs =
                new JBAccountingContextConfig[](1);
            _accountingContextConfigs[0] = JBAccountingContextConfig({
                token: JBTokenList.NATIVE,
                standard: JBTokenStandards.NATIVE
            });
            _terminalConfigurations[0] = JBTerminalConfig({
                terminal: _terminal,
                accountingContextConfigs: _accountingContextConfigs
            });

            // Create a first project to collect fees.
            _controller.launchProjectFor({
                owner: address(420), // Random.
                projectMetadata: "whatever",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations, // Set terminals to receive fees.
                memo: ""
            });

            // Create the project to test.
            _projectId = _controller.launchProjectFor({
                owner: _projectOwner,
                projectMetadata: "myIPFSHash",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
        }

        // Get a reference to the amount being paid.
        // The amount being paid is the payout limit plus two times the surplus payout limit.
        uint256 _nativePayAmount =
            _nativeCurrencyPayoutLimit + (2 * _nativeCurrencySurplusPayoutLimit);

        // Pay the project such that the `_beneficiary` receives project tokens.
        _terminal.pay{value: _nativePayAmount}({
            projectId: _projectId,
            amount: _nativePayAmount,
            token: JBTokenList.NATIVE,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Make sure the beneficiary got the expected number of tokens.
        uint256 _beneficiaryTokenBalance = PRBMath.mulDiv(
            _nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS
        ) * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE;
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);

        // Make sure the terminal holds the full native token balance.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
            _nativePayAmount
        );

        // Use the full surplus payout limit.
        vm.prank(_projectOwner);
        _terminal.payoutSurplusOf({
            projectId: _projectId,
            amount: _nativeCurrencySurplusPayoutLimit,
            currency: uint32(uint160(JBTokenList.NATIVE)),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0,
            beneficiary: payable(_beneficiary),
            memo: "MEMO"
        });

        // Make sure the beneficiary received the funds and that they are no longer in the terminal.
        uint256 _beneficiaryNativeBalance = PRBMath.mulDiv(
            _nativeCurrencySurplusPayoutLimit,
            JBConstants.MAX_FEE,
            JBConstants.MAX_FEE + _terminal.FEE()
        );
        assertEq(_beneficiary.balance, _beneficiaryNativeBalance);
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
            _nativePayAmount - _nativeCurrencySurplusPayoutLimit
        );

        // Make sure the fee was paid correctly.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
            _nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance
        );
        assertEq(address(_terminal).balance, _nativePayAmount - _beneficiaryNativeBalance);

        // Make sure the project owner got the expected number of tokens.
        assertEq(
            _tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID),
            PRBMath.mulDiv(
                _nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance,
                _data.weight,
                10 ** _NATIVE_DECIMALS
            ) * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE
        );

        // Pay out native tokens up to the payout limit. Since `splits[]` is empty, everything goes to project owner.
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            amount: _nativeCurrencyPayoutLimit,
            currency: uint32(uint160(JBTokenList.NATIVE)),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0
        });

        // Make sure the project owner received the funds which were paid out.
        uint256 _projectOwnerNativeBalance = (_nativeCurrencyPayoutLimit * JBConstants.MAX_FEE)
            / (_terminal.FEE() + JBConstants.MAX_FEE);

        // Make sure the project owner received the full amount.
        assertEq(_projectOwner.balance, _projectOwnerNativeBalance);

        // Make sure the fee was paid correctly.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
            (_nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance)
                + (_nativeCurrencyPayoutLimit - _projectOwnerNativeBalance)
        );
        assertEq(
            address(_terminal).balance,
            _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
        );

        // Make sure the project owner got the expected number of tokens.
        assertEq(
            _tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID),
            PRBMath.mulDiv(
                (_nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance)
                    + (_nativeCurrencyPayoutLimit - _projectOwnerNativeBalance),
                _data.weight,
                10 ** _NATIVE_DECIMALS
            ) * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE
        );

        // Redeem native tokens from the surplus using all of the `_beneficiary`'s tokens.
        vm.prank(_beneficiary);
        _terminal.redeemTokensOf({
            holder: _beneficiary,
            projectId: _projectId,
            token: JBTokenList.NATIVE,
            count: _beneficiaryTokenBalance,
            minReclaimed: 0,
            beneficiary: payable(_beneficiary),
            metadata: new bytes(0)
        });

        // Make sure the beneficiary doesn't have any project tokens left.
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), 0);

        // Get the expected amount of native tokens reclaimed by the redemption.
        uint256 _nativeReclaimAmount = PRBMath.mulDiv(
            PRBMath.mulDiv(
                _nativePayAmount - _nativeCurrencySurplusPayoutLimit - _nativeCurrencyPayoutLimit,
                _beneficiaryTokenBalance,
                PRBMath.mulDiv(_nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
            ),
            _metadata.redemptionRate
                + PRBMath.mulDiv(
                    _beneficiaryTokenBalance,
                    JBConstants.MAX_REDEMPTION_RATE - _metadata.redemptionRate,
                    PRBMath.mulDiv(_nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
                ),
            JBConstants.MAX_REDEMPTION_RATE
        );

        // Calculate the fee from the redemption.
        uint256 _feeAmount = _nativeReclaimAmount
            - _nativeReclaimAmount * JBConstants.MAX_FEE / (_terminal.FEE() + JBConstants.MAX_FEE);
        assertEq(
            _beneficiary.balance, _beneficiaryNativeBalance + _nativeReclaimAmount - _feeAmount
        );

        // Make sure the fee was paid correctly.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
            (_nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance)
                + (_nativeCurrencyPayoutLimit - _projectOwnerNativeBalance) + _feeAmount
        );
        assertEq(
            address(_terminal).balance,
            _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
                - (_nativeReclaimAmount - _feeAmount)
        );

        // Make sure the project owner got the expected number of the fee project's tokens by paying the fee.
        assertEq(
            _tokens.totalBalanceOf(_beneficiary, _FEE_PROJECT_ID),
            PRBMath.mulDiv(_feeAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
                * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE
        );
    }

    function testFuzzNativePayoutLimits(
        uint224 _nativeCurrencySurplusPayoutLimit,
        uint224 _nativeCurrencyPayoutLimit,
        uint256 _nativePayAmount
    ) public {
        // Make sure the amount of native tokens to pay is bounded.
        _nativePayAmount = bound(_nativePayAmount, 0, 1_000_000 * 10 ** _NATIVE_DECIMALS);

        // Make sure the values don't overflow the registry.
        unchecked {
            vm.assume(
                _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                    >= _nativeCurrencySurplusPayoutLimit
                    && _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                        >= _nativeCurrencyPayoutLimit
            );
        }

        // Package up the limits for the given terminal.
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        {
            // Specify a payout limit.
            JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](1);
            _payoutLimits[0] = JBCurrencyAmount({
                amount: _nativeCurrencyPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });

            // Specify a surplus payout limit.
            JBCurrencyAmount[] memory _surplusPayoutLimits = new JBCurrencyAmount[](1);
            _surplusPayoutLimits[0] = JBCurrencyAmount({
                amount: _nativeCurrencySurplusPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });

            _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
                terminal: address(_terminal),
                token: JBTokenList.NATIVE,
                payoutLimits: _payoutLimits,
                surplusPayoutLimits: _surplusPayoutLimits
            });
        }

        {
            // Package up the ruleset configuration.
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].data = _data;
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            JBAccountingContextConfig[] memory _accountingContextConfigs =
                new JBAccountingContextConfig[](1);
            _accountingContextConfigs[0] = JBAccountingContextConfig({
                token: JBTokenList.NATIVE,
                standard: JBTokenStandards.NATIVE
            });
            _terminalConfigurations[0] = JBTerminalConfig({
                terminal: _terminal,
                accountingContextConfigs: _accountingContextConfigs
            });

            // Create a project to collect fees.
            _controller.launchProjectFor({
                owner: address(420), // Random.
                projectMetadata: "whatever",
                rulesetConfigurations: _rulesetConfigurations, // Use the same ruleset configurations.
                terminalConfigurations: _terminalConfigurations, // set the terminals where fees will be received
                memo: ""
            });

            // Create the project to test.
            _projectId = _controller.launchProjectFor({
                owner: _projectOwner,
                projectMetadata: "myIPFSHash",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
        }

        // Make a payment to the test project to give it a starting balance. Send the tokens to the `_beneficiary`.
        _terminal.pay{value: _nativePayAmount}({
            projectId: _projectId,
            amount: _nativePayAmount,
            token: JBTokenList.NATIVE,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Make sure the beneficiary got the expected number of tokens.
        uint256 _beneficiaryTokenBalance = PRBMath.mulDiv(
            _nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS
        ) * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE;
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);

        // Make sure the terminal holds the full native token balance.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
            _nativePayAmount
        );

        // Revert if there's no surplus payout limit.
        if (_nativeCurrencySurplusPayoutLimit == 0) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_CONTROLLER_SURPLUS_PAYOUT_LIMIT()"));
            // Revert if there's no surplus, or if too much is being withdrawn.
        } else if (
            _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit > _nativePayAmount
        ) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
        }

        // Use the full surplus payout limit.
        vm.prank(_projectOwner);
        _terminal.payoutSurplusOf({
            projectId: _projectId,
            amount: _nativeCurrencySurplusPayoutLimit,
            currency: uint32(uint160(JBTokenList.NATIVE)),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0,
            beneficiary: payable(_beneficiary),
            memo: "MEMO"
        });

        // Keep a reference to the beneficiary's balance.
        uint256 _beneficiaryNativeBalance;

        // Check the collected balance if one is expected.
        if (_nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit <= _nativePayAmount) {
            // Make sure the beneficiary received the funds and that they are no longer in the terminal.
            _beneficiaryNativeBalance = PRBMath.mulDiv(
                _nativeCurrencySurplusPayoutLimit,
                JBConstants.MAX_FEE,
                JBConstants.MAX_FEE + _terminal.FEE()
            );
            assertEq(_beneficiary.balance, _beneficiaryNativeBalance);
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _nativeCurrencySurplusPayoutLimit
            );

            // Make sure the fee was paid correctly.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
                _nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance
            );
            assertEq(address(_terminal).balance, _nativePayAmount - _beneficiaryNativeBalance);

            // Make sure the beneficiary got the expected number of tokens.
            assertEq(
                _tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID),
                PRBMath.mulDiv(
                    _nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance,
                    _data.weight,
                    10 ** _NATIVE_DECIMALS
                ) * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE
            );
        } else {
            // Set the surplus payout limit for the native token to 0 if it wasn't used.
            _nativeCurrencySurplusPayoutLimit = 0;
        }

        // Revert if the payout limit is greater than the balance.
        if (_nativeCurrencyPayoutLimit > _nativePayAmount) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));

            // Revert if there's no payout limit.
        } else if (_nativeCurrencyPayoutLimit == 0) {
            vm.expectRevert(abi.encodeWithSignature("PAYOUT_LIMIT_EXCEEDED()"));
        }

        // Pay out native tokens up to the payout limit. Since `splits[]` is empty, everything goes to project owner.
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            amount: _nativeCurrencyPayoutLimit,
            currency: uint32(uint160(JBTokenList.NATIVE)),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0
        });

        uint256 _projectOwnerNativeBalance;

        // Check the payout if one is expected.
        if (_nativeCurrencyPayoutLimit <= _nativePayAmount && _nativeCurrencyPayoutLimit != 0) {
            // Make sure the project owner received the payout.
            _projectOwnerNativeBalance = (_nativeCurrencyPayoutLimit * JBConstants.MAX_FEE)
                / (_terminal.FEE() + JBConstants.MAX_FEE);
            assertEq(_projectOwner.balance, _projectOwnerNativeBalance);
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _nativeCurrencySurplusPayoutLimit - _nativeCurrencyPayoutLimit
            );

            // Make sure the fee was paid correctly.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
                (_nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance)
                    + (_nativeCurrencyPayoutLimit - _projectOwnerNativeBalance)
            );
            assertEq(
                address(_terminal).balance,
                _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
            );

            // Make sure the project owner got the expected number of the fee project's tokens.
            assertEq(
                _tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID),
                PRBMath.mulDiv(
                    (_nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance)
                        + (_nativeCurrencyPayoutLimit - _projectOwnerNativeBalance),
                    _data.weight,
                    10 ** _NATIVE_DECIMALS
                ) * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE
            );
        }

        // Reclaim native tokens from the surplus by redeeming all of the `_beneficiary`'s tokens.
        vm.prank(_beneficiary);
        _terminal.redeemTokensOf({
            holder: _beneficiary,
            projectId: _projectId,
            count: _beneficiaryTokenBalance,
            token: JBTokenList.NATIVE,
            minReclaimed: 0,
            beneficiary: payable(_beneficiary),
            metadata: new bytes(0)
        });

        // Make sure the beneficiary doesn't have tokens left.
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), 0);

        // Check for a new beneficiary balance if one is expected.
        if (_nativePayAmount > _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit) {
            // Get the expected amount reclaimed.
            uint256 _nativeReclaimAmount = PRBMath.mulDiv(
                PRBMath.mulDiv(
                    _nativePayAmount - _nativeCurrencySurplusPayoutLimit
                        - _nativeCurrencyPayoutLimit,
                    _beneficiaryTokenBalance,
                    PRBMath.mulDiv(_nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
                ),
                _metadata.redemptionRate
                    + PRBMath.mulDiv(
                        _beneficiaryTokenBalance,
                        JBConstants.MAX_REDEMPTION_RATE - _metadata.redemptionRate,
                        PRBMath.mulDiv(_nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
                    ),
                JBConstants.MAX_REDEMPTION_RATE
            );
            // Calculate the fee from the redemption.
            uint256 _feeAmount = _nativeReclaimAmount
                - _nativeReclaimAmount * JBConstants.MAX_FEE / (_terminal.FEE() + JBConstants.MAX_FEE);
            assertEq(
                _beneficiary.balance, _beneficiaryNativeBalance + _nativeReclaimAmount - _feeAmount
            );

            // Make sure the fee was paid correctly.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
                (_nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance)
                    + (_nativeCurrencyPayoutLimit - _projectOwnerNativeBalance) + _feeAmount
            );
            assertEq(
                address(_terminal).balance,
                _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
                    - (_nativeReclaimAmount - _feeAmount)
            );

            // Make sure the project owner got the expected number of tokens from the fee.
            assertEq(
                _tokens.totalBalanceOf(_beneficiary, _FEE_PROJECT_ID),
                PRBMath.mulDiv(_feeAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
                    * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE
            );
        }
    }

    function testFuzzNativePayoutLimitsWithRevertingFeeProject(
        uint224 _nativeCurrencySurplusPayoutLimit,
        uint224 _nativeCurrencyPayoutLimit,
        uint256 _nativePayAmount,
        bool _feeProjectAcceptsToken
    ) public {
        // Make sure the amount of native tokens to pay is bounded.
        _nativePayAmount = bound(_nativePayAmount, 0, 1_000_000 * 10 ** _NATIVE_DECIMALS);

        // Make sure the values don't overflow the registry.
        unchecked {
            vm.assume(
                _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                    >= _nativeCurrencySurplusPayoutLimit
                    && _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                        >= _nativeCurrencyPayoutLimit
            );
        }

        // Package up the limits for the given terminal.
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        {
            // Specify a payout limit.
            JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](1);
            _payoutLimits[0] = JBCurrencyAmount({
                amount: _nativeCurrencyPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });

            // Specify a surplus payout limit.
            JBCurrencyAmount[] memory _surplusPayoutLimits = new JBCurrencyAmount[](1);
            _surplusPayoutLimits[0] = JBCurrencyAmount({
                amount: _nativeCurrencySurplusPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });

            _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
                terminal: address(_terminal),
                token: JBTokenList.NATIVE,
                payoutLimits: _payoutLimits,
                surplusPayoutLimits: _surplusPayoutLimits
            });
        }

        {
            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            JBAccountingContextConfig[] memory _accountingContextConfigs =
                new JBAccountingContextConfig[](1);
            _accountingContextConfigs[0] = JBAccountingContextConfig({
                token: JBTokenList.NATIVE,
                standard: JBTokenStandards.NATIVE
            });

            _terminalConfigurations[0] = JBTerminalConfig({
                terminal: _terminal,
                accountingContextConfigs: _accountingContextConfigs
            });

            // Create a first project to collect fees.
            _controller.launchProjectFor({
                owner: address(420), // Random.
                projectMetadata: "whatever",
                rulesetConfigurations: new JBRulesetConfig[](0), // No ruleset config will force revert when paid.
                // Set the fee collecting terminal's native token accounting context if the test calls for doing so.
                terminalConfigurations: _feeProjectAcceptsToken
                    ? _terminalConfigurations
                    : new JBTerminalConfig[](0), // Set terminals to receive fees.
                memo: ""
            });

            // Package up the ruleset configuration.
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].data = _data;
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            // Create the project to test.
            _projectId = _controller.launchProjectFor({
                owner: _projectOwner,
                projectMetadata: "myIPFSHash",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
        }

        // Make a payment to the project to give it a starting balance. Send the tokens to the `_beneficiary`.
        _terminal.pay{value: _nativePayAmount}({
            projectId: _projectId,
            amount: _nativePayAmount,
            token: JBTokenList.NATIVE,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Make sure the beneficiary got the expected number of tokens.
        uint256 _beneficiaryTokenBalance = PRBMath.mulDiv(
            _nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS
        ) * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE;
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);

        // Make sure the terminal holds the full native token balance.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
            _nativePayAmount
        );

        // Revert if there's no surplus payout limit.
        if (_nativeCurrencySurplusPayoutLimit == 0) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_CONTROLLER_SURPLUS_PAYOUT_LIMIT()"));
            // Revert if there's no surplus, or if too much is being withdrawn.
        } else if (
            _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit > _nativePayAmount
        ) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
        }

        // Use the full surplus payout limit.
        vm.prank(_projectOwner);
        _terminal.payoutSurplusOf({
            projectId: _projectId,
            amount: _nativeCurrencySurplusPayoutLimit,
            currency: uint32(uint160(JBTokenList.NATIVE)),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0,
            beneficiary: payable(_beneficiary),
            memo: "MEMO"
        });

        // Keep a reference to the beneficiary's balance.
        uint256 _beneficiaryNativeBalance;

        // Check the collected balance if one is expected.
        if (_nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit <= _nativePayAmount) {
            // Make sure the beneficiary received the funds and that they are no longer in the terminal.
            _beneficiaryNativeBalance = PRBMath.mulDiv(
                _nativeCurrencySurplusPayoutLimit,
                JBConstants.MAX_FEE,
                JBConstants.MAX_FEE + _terminal.FEE()
            );
            assertEq(_beneficiary.balance, _beneficiaryNativeBalance);
            // Make sure the fee stays in the terminal.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _beneficiaryNativeBalance
            );

            // Make sure the fee was not taken.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
                0
            );
            assertEq(address(_terminal).balance, _nativePayAmount - _beneficiaryNativeBalance);

            // Make sure the beneficiary got no tokens.
            assertEq(_tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID), 0);
        } else {
            // Set the native token's surplus payout limit to 0 if it wasn't used.
            _nativeCurrencySurplusPayoutLimit = 0;
        }

        // Revert if the payout limit is greater than the balance.
        if (_nativeCurrencyPayoutLimit > _nativePayAmount) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));

            // Revert if there's no payout limit.
        } else if (_nativeCurrencyPayoutLimit == 0) {
            vm.expectRevert(abi.encodeWithSignature("PAYOUT_LIMIT_EXCEEDED()"));
        }

        // Pay out native tokens up to the payout limit. Since `splits[]` is empty, everything goes to project owner.
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            amount: _nativeCurrencyPayoutLimit,
            currency: uint32(uint160(JBTokenList.NATIVE)),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0
        });

        uint256 _projectOwnerNativeBalance;

        // Check the received payout if one is expected.
        if (_nativeCurrencyPayoutLimit <= _nativePayAmount && _nativeCurrencyPayoutLimit != 0) {
            // Make sure the project owner received the funds that were paid out.
            _projectOwnerNativeBalance = (_nativeCurrencyPayoutLimit * JBConstants.MAX_FEE)
                / (_terminal.FEE() + JBConstants.MAX_FEE);
            assertEq(_projectOwner.balance, _projectOwnerNativeBalance);
            // Make sure the fee stays in the terminal.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
            );

            // Make sure the fee was paid correctly.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
                0
            );
            assertEq(
                address(_terminal).balance,
                _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
            );

            // Make sure the project owner got the expected number of tokens.
            assertEq(_tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID), 0);
        }

        // Reclaim native tokens from the surplus by redeeming all of the `_beneficiary`'s tokens.
        vm.prank(_beneficiary);
        _terminal.redeemTokensOf({
            holder: _beneficiary,
            projectId: _projectId,
            count: _beneficiaryTokenBalance,
            token: JBTokenList.NATIVE,
            minReclaimed: 0,
            beneficiary: payable(_beneficiary),
            metadata: new bytes(0)
        });

        // Make sure the beneficiary doesn't have tokens left.
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), 0);

        // Check for a new beneficiary balance if one is expected.
        if (_nativePayAmount > _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit) {
            // Get the expected amount reclaimed.
            uint256 _nativeReclaimAmount = PRBMath.mulDiv(
                PRBMath.mulDiv(
                    _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance,
                    _beneficiaryTokenBalance,
                    PRBMath.mulDiv(_nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
                ),
                _metadata.redemptionRate
                    + PRBMath.mulDiv(
                        _beneficiaryTokenBalance,
                        JBConstants.MAX_REDEMPTION_RATE - _metadata.redemptionRate,
                        PRBMath.mulDiv(_nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
                    ),
                JBConstants.MAX_REDEMPTION_RATE
            );

            // Calculate the fee from the redemption.
            uint256 _feeAmount = _nativeReclaimAmount
                - _nativeReclaimAmount * JBConstants.MAX_FEE / (_terminal.FEE() + JBConstants.MAX_FEE);
            assertEq(
                _beneficiary.balance, _beneficiaryNativeBalance + _nativeReclaimAmount - _feeAmount
            );
            // Make sure the fee stays in the terminal.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
                    - (_nativeReclaimAmount - _feeAmount)
            );

            // Make sure the fee was paid correctly.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
                0
            );
            assertEq(
                address(_terminal).balance,
                _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
                    - (_nativeReclaimAmount - _feeAmount)
            );

            // Make sure the project owner got the expected number of tokens from the fee.
            assertEq(_tokens.totalBalanceOf(_beneficiary, _FEE_PROJECT_ID), 0);
        }
    }

    function testFuzzNativePayoutLimitsForTheFeeProject(
        uint224 _nativeCurrencySurplusPayoutLimit,
        uint224 _nativeCurrencyPayoutLimit,
        uint256 _nativePayAmount
    ) public {
        // Make sure the amount of native tokens to pay is bounded.
        _nativePayAmount = bound(_nativePayAmount, 0, 1_000_000 * 10 ** _NATIVE_DECIMALS);

        // Make sure the values don't overflow the registry.
        unchecked {
            vm.assume(
                _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                    >= _nativeCurrencySurplusPayoutLimit
                    && _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                        >= _nativeCurrencyPayoutLimit
            );
        }

        // Package up the limits for the given terminal.
        JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);
        {
            // Specify a payout limit.
            JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](1);
            _payoutLimits[0] = JBCurrencyAmount({
                amount: _nativeCurrencyPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });

            // Specify a surplus payout limit.
            JBCurrencyAmount[] memory _surplusPayoutLimits = new JBCurrencyAmount[](1);
            _surplusPayoutLimits[0] = JBCurrencyAmount({
                amount: _nativeCurrencySurplusPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });

            _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
                terminal: address(_terminal),
                token: JBTokenList.NATIVE,
                payoutLimits: _payoutLimits,
                surplusPayoutLimits: _surplusPayoutLimits
            });
        }

        {
            // Package up the ruleset configuration.
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].data = _data;
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            JBAccountingContextConfig[] memory _accountingContextConfigs =
                new JBAccountingContextConfig[](1);
            _accountingContextConfigs[0] = JBAccountingContextConfig({
                token: JBTokenList.NATIVE,
                standard: JBTokenStandards.NATIVE
            });

            _terminalConfigurations[0] = JBTerminalConfig({
                terminal: _terminal,
                accountingContextConfigs: _accountingContextConfigs
            });

            // Create the project to test.
            _projectId = _controller.launchProjectFor({
                owner: _projectOwner,
                projectMetadata: "myIPFSHash",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
        }

        // Make a payment to the project to give it a starting balance. Send the tokens to the `_beneficiary`.
        _terminal.pay{value: _nativePayAmount}({
            projectId: _projectId,
            amount: _nativePayAmount,
            token: JBTokenList.NATIVE,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Make sure the beneficiary got the expected number of tokens.
        uint256 _beneficiaryTokenBalance = PRBMath.mulDiv(
            _nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS
        ) * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE;
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);

        // Make sure the terminal holds the full native token balance.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
            _nativePayAmount
        );

        // Revert if there's no surplus payout limit.
        if (_nativeCurrencySurplusPayoutLimit == 0) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_CONTROLLER_SURPLUS_PAYOUT_LIMIT()"));
            // Revert if there's no surplus, or if too much is being withdrawn.
        } else if (
            _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit > _nativePayAmount
        ) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
        }

        // Use the full surplus payout limit.
        vm.prank(_projectOwner);
        _terminal.payoutSurplusOf({
            projectId: _projectId,
            amount: _nativeCurrencySurplusPayoutLimit,
            currency: uint32(uint160(JBTokenList.NATIVE)),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0,
            beneficiary: payable(_beneficiary),
            memo: "MEMO"
        });

        // Keep a reference to the beneficiary's balance.
        uint256 _beneficiaryNativeBalance;

        // Check the collected balance if one is expected.
        if (_nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit <= _nativePayAmount) {
            // Make sure the beneficiary received the funds and that they are no longer in the terminal.
            _beneficiaryNativeBalance = PRBMath.mulDiv(
                _nativeCurrencySurplusPayoutLimit,
                JBConstants.MAX_FEE,
                JBConstants.MAX_FEE + _terminal.FEE()
            );
            assertEq(_beneficiary.balance, _beneficiaryNativeBalance);
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _beneficiaryNativeBalance
            );
            assertEq(address(_terminal).balance, _nativePayAmount - _beneficiaryNativeBalance);

            // Make sure the beneficiary got the expected number of tokens.
            assertEq(
                _tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID),
                PRBMath.mulDiv(
                    _nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance,
                    _data.weight,
                    10 ** _NATIVE_DECIMALS
                ) * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE
            );
        } else {
            // Set the surplus payout limit for the native token to 0 if it wasn't used.
            _nativeCurrencySurplusPayoutLimit = 0;
        }

        // Revert if the payout limit is greater than the balance.
        if (_nativeCurrencyPayoutLimit > _nativePayAmount) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));

            // Revert if there's no payout limit.
        } else if (_nativeCurrencyPayoutLimit == 0) {
            vm.expectRevert(abi.encodeWithSignature("PAYOUT_LIMIT_EXCEEDED()"));
        }

        // Pay out native tokens up to the payout limit. Since `splits[]` is empty, everything goes to project owner.
        _terminal.sendPayoutsOf({
            projectId: _projectId,
            amount: _nativeCurrencyPayoutLimit,
            currency: uint32(uint160(JBTokenList.NATIVE)),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0
        });

        uint256 _projectOwnerNativeBalance;

        // Check the received payout if one is expected.
        if (_nativeCurrencyPayoutLimit <= _nativePayAmount && _nativeCurrencyPayoutLimit != 0) {
            // Make sure the project owner received the funds that were paid out.
            _projectOwnerNativeBalance = (_nativeCurrencyPayoutLimit * JBConstants.MAX_FEE)
                / (_terminal.FEE() + JBConstants.MAX_FEE);
            assertEq(_projectOwner.balance, _projectOwnerNativeBalance);
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
            );
            assertEq(
                address(_terminal).balance,
                _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
            );

            // Make sure the project owner got the expected number of tokens.
            assertEq(
                _tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID),
                PRBMath.mulDiv(
                    (_nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance)
                        + (_nativeCurrencyPayoutLimit - _projectOwnerNativeBalance),
                    _data.weight,
                    10 ** _NATIVE_DECIMALS
                ) * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE
            );
        }

        // Reclaim native tokens from the surplus by redeeming all of the `_beneficiary`'s tokens.
        vm.prank(_beneficiary);
        _terminal.redeemTokensOf({
            holder: _beneficiary,
            projectId: _projectId,
            count: _beneficiaryTokenBalance,
            token: JBTokenList.NATIVE,
            minReclaimed: 0,
            beneficiary: payable(_beneficiary),
            metadata: new bytes(0)
        });

        // Check for a new beneficiary balance if one is expected.
        if (_nativePayAmount > _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit) {
            // Keep a reference to the total amount paid, including from fees.
            uint256 _totalPaid = _nativePayAmount
                + (_nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance)
                + (_nativeCurrencyPayoutLimit - _projectOwnerNativeBalance);

            // Get the expected amount reclaimed.
            uint256 _nativeReclaimAmount = PRBMath.mulDiv(
                PRBMath.mulDiv(
                    _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance,
                    _beneficiaryTokenBalance,
                    PRBMath.mulDiv(_totalPaid, _data.weight, 10 ** _NATIVE_DECIMALS)
                ),
                _metadata.redemptionRate
                    + PRBMath.mulDiv(
                        _beneficiaryTokenBalance,
                        JBConstants.MAX_REDEMPTION_RATE - _metadata.redemptionRate,
                        PRBMath.mulDiv(_totalPaid, _data.weight, 10 ** _NATIVE_DECIMALS)
                    ),
                JBConstants.MAX_REDEMPTION_RATE
            );
            // Calculate the fee from the redemption.
            uint256 _feeAmount = _nativeReclaimAmount
                - _nativeReclaimAmount * JBConstants.MAX_FEE / (_terminal.FEE() + JBConstants.MAX_FEE);

            // Make sure the beneficiary received tokens from the fee just paid.
            assertEq(
                _tokens.totalBalanceOf(_beneficiary, _projectId),
                PRBMath.mulDiv(_feeAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
                    * _metadata.reservedRate / JBConstants.MAX_RESERVED_RATE
            );

            // Make sure the beneficiary received the funds.
            assertEq(
                _beneficiary.balance, _beneficiaryNativeBalance + _nativeReclaimAmount - _feeAmount
            );

            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
                    - (_nativeReclaimAmount - _feeAmount)
            );
            assertEq(
                address(_terminal).balance,
                _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
                    - (_nativeReclaimAmount - _feeAmount)
            );
        }
    }

    function testFuzzMultiCurrencyPayoutLimits(
        uint224 _nativeCurrencySurplusPayoutLimit,
        uint224 _nativeCurrencyPayoutLimit,
        uint256 _nativePayAmount,
        uint224 _usdCurrencySurplusPayoutLimit,
        uint224 _usdCurrencyPayoutLimit,
        uint256 _usdcPayAmount
    ) public {
        // Make sure the amount of native tokens to pay is bounded.
        _nativePayAmount = bound(_nativePayAmount, 0, 1_000_000 * 10 ** _NATIVE_DECIMALS);
        _usdcPayAmount = bound(_usdcPayAmount, 0, 1_000_000 * 10 ** _usdcToken.decimals());

        // Make sure the values don't overflow the registry.
        unchecked {
            // vm.assume(_nativeCurrencySurplusPayoutLimit + _cumulativePayoutLimit  >= _nativeCurrencySurplusPayoutLimit && _nativeCurrencySurplusPayoutLimit + _cumulativePayoutLimit >= _cumulativePayoutLimit);
            // vm.assume(_usdCurrencySurplusPayoutLimit + (_usdCurrencyPayoutLimit + PRBMath.mulDiv(_nativeCurrencyPayoutLimit, _USD_PRICE_PER_NATIVE, 10**_PRICE_FEED_DECIMALS))*2 >= _usdCurrencySurplusPayoutLimit && _usdCurrencySurplusPayoutLimit + _usdCurrencyPayoutLimit >= _usdCurrencyPayoutLimit);
            vm.assume(
                _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                    >= _nativeCurrencySurplusPayoutLimit
                    && _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                        >= _nativeCurrencyPayoutLimit
            );
            vm.assume(
                _usdCurrencySurplusPayoutLimit + _usdCurrencyPayoutLimit
                    >= _usdCurrencySurplusPayoutLimit
                    && _usdCurrencySurplusPayoutLimit + _usdCurrencyPayoutLimit
                        >= _usdCurrencyPayoutLimit
            );
        }

        {
            // Package up the limits for the given terminal.
            JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](1);

            // Specify payout limits.
            JBCurrencyAmount[] memory _payoutLimits = new JBCurrencyAmount[](2);
            _payoutLimits[0] = JBCurrencyAmount({
                amount: _nativeCurrencyPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });
            _payoutLimits[1] = JBCurrencyAmount({
                amount: _usdCurrencyPayoutLimit,
                currency: uint32(uint160(address(_usdcToken)))
            });

            // Specify surplus payout limits.
            JBCurrencyAmount[] memory _surplusPayoutLimits = new JBCurrencyAmount[](2);
            _surplusPayoutLimits[0] = JBCurrencyAmount({
                amount: _nativeCurrencySurplusPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });
            _surplusPayoutLimits[1] = JBCurrencyAmount({
                amount: _usdCurrencySurplusPayoutLimit,
                currency: uint32(uint160(address(_usdcToken)))
            });

            _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
                terminal: address(_terminal),
                token: JBTokenList.NATIVE,
                payoutLimits: _payoutLimits,
                surplusPayoutLimits: _surplusPayoutLimits
            });

            // Package up the ruleset configuration.
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].data = _data;
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
            JBAccountingContextConfig[] memory _accountingContextConfigs =
                new JBAccountingContextConfig[](2);
            _accountingContextConfigs[0] = JBAccountingContextConfig({
                token: JBTokenList.NATIVE,
                standard: JBTokenStandards.NATIVE
            });
            _accountingContextConfigs[1] = JBAccountingContextConfig({
                token: address(_usdcToken),
                standard: JBTokenStandards.ERC20
            });

            _terminalConfigurations[0] = JBTerminalConfig({
                terminal: _terminal,
                accountingContextConfigs: _accountingContextConfigs
            });

            // Create a first project to collect fees.
            _controller.launchProjectFor({
                owner: address(420), // Random.
                projectMetadata: "whatever",
                rulesetConfigurations: _rulesetConfigurations, // Use the same ruleset configurations.
                terminalConfigurations: _terminalConfigurations, // Set terminals to receive fees.
                memo: ""
            });

            // Create the project to test.
            _projectId = _controller.launchProjectFor({
                owner: _projectOwner,
                projectMetadata: "myIPFSHash",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations,
                memo: ""
            });
        }

        // Add a price feed to convert from native token to USD currencies.
        {
            vm.startPrank(_projectOwner);
            MockPriceFeed _priceFeedNativeUsd =
                new MockPriceFeed(_USD_PRICE_PER_NATIVE, _PRICE_FEED_DECIMALS);
            vm.label(address(_priceFeedNativeUsd), "Mock Price Feed Native-USDC");

            _prices.addPriceFeedFor({
                projectId: 0,
                pricingCurrency: uint32(uint160(address(_usdcToken))),
                unitCurrency: uint32(uint160(JBTokenList.NATIVE)),
                priceFeed: _priceFeedNativeUsd
            });

            vm.stopPrank();
        }

        // Make a payment to the project to give it a starting balance. Send the tokens to the `_beneficiary`.
        _terminal.pay{value: _nativePayAmount}({
            projectId: _projectId,
            amount: _nativePayAmount,
            token: JBTokenList.NATIVE,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Make sure the beneficiary got the expected number of tokens from the native token payment.
        uint256 _beneficiaryTokenBalance = _unreservedPortion(
            PRBMath.mulDiv(_nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
        );
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);
        // Mint USDC to this contract.
        _usdcToken.mint(address(this), _usdcPayAmount);

        // Allow the terminal to spend the USDC.
        _usdcToken.approve(address(_terminal), _usdcPayAmount);

        // Make a payment to the project to give it a starting balance. Send the tokens to the `_beneficiary`.
        _terminal.pay({
            projectId: _projectId,
            amount: _usdcPayAmount,
            token: address(_usdcToken),
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Make sure the terminal holds the full native token balance.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
            _nativePayAmount
        );
        // Make sure the USDC is accounted for.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, address(_usdcToken)),
            _usdcPayAmount
        );
        assertEq(_usdcToken.balanceOf(address(_terminal)), _usdcPayAmount);

        {
            // Convert the USD amount to a native token amount, by way of the current weight used for issuance.
            uint256 _usdWeightedPayAmountConvertedToNative = PRBMath.mulDiv(
                _usdcPayAmount,
                _data.weight,
                PRBMath.mulDiv(
                    _USD_PRICE_PER_NATIVE, 10 ** _usdcToken.decimals(), 10 ** _PRICE_FEED_DECIMALS
                )
            );

            // Make sure the beneficiary got the expected number of tokens from the USDC payment.
            _beneficiaryTokenBalance += _unreservedPortion(_usdWeightedPayAmountConvertedToNative);
            assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);
        }

        // Revert if there's no surplus payout limit for the native token.
        if (_nativeCurrencySurplusPayoutLimit == 0) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_CONTROLLER_SURPLUS_PAYOUT_LIMIT()"));
        } else if (
            _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                + _toNative(_usdCurrencyPayoutLimit) > _nativePayAmount
        ) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
        }

        // Use the full surplus payout limit for the native token.
        vm.prank(_projectOwner);
        _terminal.payoutSurplusOf({
            projectId: _projectId,
            amount: _nativeCurrencySurplusPayoutLimit,
            currency: uint32(uint160(JBTokenList.NATIVE)),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0,
            beneficiary: payable(_beneficiary),
            memo: "MEMO"
        });

        // Keep a reference to the beneficiary's native token balance.
        uint256 _beneficiaryNativeBalance;

        // Check the collected balance if one is expected.
        if (
            _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                + _toNative(_usdCurrencyPayoutLimit) <= _nativePayAmount
        ) {
            // Make sure the beneficiary received the funds and that they are no longer in the terminal.
            _beneficiaryNativeBalance = PRBMath.mulDiv(
                _nativeCurrencySurplusPayoutLimit,
                JBConstants.MAX_FEE,
                JBConstants.MAX_FEE + _terminal.FEE()
            );
            assertEq(_beneficiary.balance, _beneficiaryNativeBalance);
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _nativeCurrencySurplusPayoutLimit
            );

            // Make sure the fee was paid correctly.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
                _nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance
            );
            assertEq(address(_terminal).balance, _nativePayAmount - _beneficiaryNativeBalance);

            // Make sure the beneficiary got the expected number of tokens.
            assertEq(
                _tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID),
                _unreservedPortion(
                    PRBMath.mulDiv(
                        _nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance,
                        _data.weight,
                        10 ** _NATIVE_DECIMALS
                    )
                )
            );
        } else {
            // Set the surplus payout limit for the native token to 0 if it wasn't used.
            _nativeCurrencySurplusPayoutLimit = 0;
        }

        // Revert if there's no surplus payout limit for the native token.
        if (_usdCurrencySurplusPayoutLimit == 0) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_CONTROLLER_SURPLUS_PAYOUT_LIMIT()"));
            // revert if the USD surplus payout limit resolved to native tokens is greater than 0, and there is sufficient surplus to pull from including what was already pulled from.
        } else if (
            _toNative(_usdCurrencySurplusPayoutLimit) > 0
                && _toNative(_usdCurrencySurplusPayoutLimit + _usdCurrencyPayoutLimit)
                    + _nativeCurrencyPayoutLimit + _nativeCurrencySurplusPayoutLimit > _nativePayAmount
        ) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
        }

        // Use the full surplus payout limit for the native token.
        vm.prank(_projectOwner);
        _terminal.payoutSurplusOf({
            projectId: _projectId,
            amount: _usdCurrencySurplusPayoutLimit,
            currency: uint32(uint160(address(_usdcToken))),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0,
            beneficiary: payable(_beneficiary),
            memo: "MEMO"
        });

        // Check the collected balance if one is expected.
        if (
            _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                + _toNative(_usdCurrencySurplusPayoutLimit + _usdCurrencyPayoutLimit)
                <= _nativePayAmount
        ) {
            // Make sure the beneficiary received the funds and that they are no longer in the terminal.
            _beneficiaryNativeBalance += PRBMath.mulDiv(
                _toNative(_usdCurrencySurplusPayoutLimit),
                JBConstants.MAX_FEE,
                JBConstants.MAX_FEE + _terminal.FEE()
            );
            assertEq(_beneficiary.balance, _beneficiaryNativeBalance);
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _nativeCurrencySurplusPayoutLimit
                    - _toNative(_usdCurrencySurplusPayoutLimit)
            );

            // Make sure the fee was paid correctly.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
                _nativeCurrencySurplusPayoutLimit + _toNative(_usdCurrencySurplusPayoutLimit)
                    - _beneficiaryNativeBalance
            );
            assertEq(address(_terminal).balance, _nativePayAmount - _beneficiaryNativeBalance);

            // Make sure the beneficiary got the expected number of tokens.
            assertEq(
                _tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID),
                _unreservedPortion(
                    PRBMath.mulDiv(
                        _nativeCurrencySurplusPayoutLimit
                            + _toNative(_usdCurrencySurplusPayoutLimit) - _beneficiaryNativeBalance,
                        _data.weight,
                        10 ** _NATIVE_DECIMALS
                    )
                )
            );
        } else {
            // Set the surplus payout limit for the native token to 0 if it wasn't used.
            _usdCurrencySurplusPayoutLimit = 0;
        }

        // Payout limits
        {
            // Revert if the payout limit is greater than the balance.
            if (_nativeCurrencyPayoutLimit > _nativePayAmount) {
                vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
                // Revert if there's no payout limit.
            } else if (_nativeCurrencyPayoutLimit == 0) {
                vm.expectRevert(abi.encodeWithSignature("PAYOUT_LIMIT_EXCEEDED()"));
            }

            // Pay out native tokens up to the payout limit. Since `splits[]` is empty, everything goes to project owner.
            _terminal.sendPayoutsOf({
                projectId: _projectId,
                amount: _nativeCurrencyPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE)),
                token: JBTokenList.NATIVE,
                minReturnedTokens: 0
            });

            uint256 _projectOwnerNativeBalance;

            // Check the received payout if one is expected.
            if (_nativeCurrencyPayoutLimit <= _nativePayAmount && _nativeCurrencyPayoutLimit != 0) {
                // Make sure the project owner received the funds that were paid out.
                _projectOwnerNativeBalance = (_nativeCurrencyPayoutLimit * JBConstants.MAX_FEE)
                    / (_terminal.FEE() + JBConstants.MAX_FEE);
                assertEq(_projectOwner.balance, _projectOwnerNativeBalance);
                assertEq(
                    jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                    _nativePayAmount - _nativeCurrencySurplusPayoutLimit
                        - _toNative(_usdCurrencySurplusPayoutLimit) - _nativeCurrencyPayoutLimit
                );

                // Make sure the fee was paid correctly.
                assertEq(
                    jbTerminalStore().balanceOf(
                        address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE
                    ),
                    _nativeCurrencySurplusPayoutLimit + _toNative(_usdCurrencySurplusPayoutLimit)
                        - _beneficiaryNativeBalance + _nativeCurrencyPayoutLimit
                        - _projectOwnerNativeBalance
                );
                assertEq(
                    address(_terminal).balance,
                    _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
                );

                // Make sure the project owner got the expected number of tokens.
                // assertEq(_tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID), _unreservedPortion(PRBMath.mulDiv(_nativeCurrencySurplusPayoutLimit + _toNative(_usdCurrencySurplusPayoutLimit) - _beneficiaryNativeBalance + _nativeCurrencyPayoutLimit - _projectOwnerNativeBalance, _data.weight, 10 ** _NATIVE_DECIMALS)));
            }

            // Revert if the payout limit is greater than the balance.
            if (
                _nativeCurrencyPayoutLimit <= _nativePayAmount
                    && _toNative(_usdCurrencyPayoutLimit) + _nativeCurrencyPayoutLimit
                        > _nativePayAmount
            ) {
                vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
            } else if (
                _nativeCurrencyPayoutLimit > _nativePayAmount
                    && _toNative(_usdCurrencyPayoutLimit) > _nativePayAmount
            ) {
                vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
                // Revert if there's no payout limit.
            } else if (_usdCurrencyPayoutLimit == 0) {
                vm.expectRevert(abi.encodeWithSignature("PAYOUT_LIMIT_EXCEEDED()"));
            }

            // Pay out native tokens up to the payout limit. Since `splits[]` is empty, everything goes to project owner.
            _terminal.sendPayoutsOf({
                projectId: _projectId,
                amount: _usdCurrencyPayoutLimit,
                currency: uint32(uint160(address(_usdcToken))),
                token: JBTokenList.NATIVE,
                minReturnedTokens: 0
            });

            // Check the received payout if one is expected.
            if (
                _toNative(_usdCurrencyPayoutLimit) + _nativeCurrencyPayoutLimit <= _nativePayAmount
                    && _usdCurrencyPayoutLimit > 0
            ) {
                // Make sure the project owner received the funds that were paid out.
                _projectOwnerNativeBalance += (
                    _toNative(_usdCurrencyPayoutLimit) * JBConstants.MAX_FEE
                ) / (_terminal.FEE() + JBConstants.MAX_FEE);
                assertEq(_projectOwner.balance, _projectOwnerNativeBalance);
                assertEq(
                    jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                    _nativePayAmount - _nativeCurrencySurplusPayoutLimit
                        - _toNative(_usdCurrencySurplusPayoutLimit) - _nativeCurrencyPayoutLimit
                        - _toNative(_usdCurrencyPayoutLimit)
                );

                // Make sure the fee was paid correctly.
                assertEq(
                    jbTerminalStore().balanceOf(
                        address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE
                    ),
                    (
                        _nativeCurrencySurplusPayoutLimit
                            + _toNative(_usdCurrencySurplusPayoutLimit) - _beneficiaryNativeBalance
                    )
                        + (
                            _nativeCurrencyPayoutLimit + _toNative(_usdCurrencyPayoutLimit)
                                - _projectOwnerNativeBalance
                        )
                );
                assertEq(
                    address(_terminal).balance,
                    _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
                );
            }
        }

        // Keep a reference to the remaining native token surplus.
        uint256 _nativeSurplus = _nativeCurrencyPayoutLimit + _toNative(_usdCurrencyPayoutLimit)
            + _nativeCurrencySurplusPayoutLimit + _toNative(_usdCurrencySurplusPayoutLimit)
            >= _nativePayAmount
            ? 0
            : _nativePayAmount - _nativeCurrencyPayoutLimit - _toNative(_usdCurrencyPayoutLimit)
                - _nativeCurrencySurplusPayoutLimit - _toNative(_usdCurrencySurplusPayoutLimit);

        // Keep a reference to the remaining native token balance.
        uint256 _nativeBalance = _nativePayAmount - _nativeCurrencySurplusPayoutLimit
            - _toNative(_usdCurrencySurplusPayoutLimit);
        if (_nativeCurrencyPayoutLimit <= _nativePayAmount) {
            _nativeBalance -= _nativeCurrencyPayoutLimit;
            if (_toNative(_usdCurrencyPayoutLimit) + _nativeCurrencyPayoutLimit < _nativePayAmount)
            {
                _nativeBalance -= _toNative(_usdCurrencyPayoutLimit);
            }
        } else if (_toNative(_usdCurrencyPayoutLimit) <= _nativePayAmount) {
            _nativeBalance -= _toNative(_usdCurrencyPayoutLimit);
        }

        // Make sure it's correct.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
            _nativeBalance
        );

        // Make sure the USDC surplus is correct.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, address(_usdcToken)),
            _usdcPayAmount
        );

        // Make sure the total token supply is correct.
        assertEq(
            _controller.totalTokenSupplyWithReservedTokensOf(_projectId),
            PRBMath.mulDiv(
                _beneficiaryTokenBalance,
                JBConstants.MAX_RESERVED_RATE,
                JBConstants.MAX_RESERVED_RATE - _metadata.reservedRate
            )
        );

        // Keep a reference to the amount of native tokens being reclaimed.
        uint256 _nativeReclaimAmount;

        vm.startPrank(_beneficiary);

        // If there's surplus.
        if (
            _toNative(
                PRBMath.mulDiv(_usdcPayAmount, 10 ** _NATIVE_DECIMALS, 10 ** _usdcToken.decimals())
            ) + _nativeSurplus > 0
        ) {
            // Get the expected amount reclaimed.
            _nativeReclaimAmount = PRBMath.mulDiv(
                PRBMath.mulDiv(
                    _toNative(
                        PRBMath.mulDiv(
                            _usdcPayAmount, 10 ** _NATIVE_DECIMALS, 10 ** _usdcToken.decimals()
                        )
                    ) + _nativeSurplus,
                    _beneficiaryTokenBalance,
                    PRBMath.mulDiv(
                        _beneficiaryTokenBalance,
                        JBConstants.MAX_RESERVED_RATE,
                        JBConstants.MAX_RESERVED_RATE - _metadata.reservedRate
                    )
                ),
                _metadata.redemptionRate
                    + PRBMath.mulDiv(
                        _beneficiaryTokenBalance,
                        JBConstants.MAX_REDEMPTION_RATE - _metadata.redemptionRate,
                        PRBMath.mulDiv(
                            _beneficiaryTokenBalance,
                            JBConstants.MAX_RESERVED_RATE,
                            JBConstants.MAX_RESERVED_RATE - _metadata.reservedRate
                        )
                    ),
                JBConstants.MAX_REDEMPTION_RATE
            );

            // If there is more to reclaim than there are native tokens in the tank.
            if (_nativeReclaimAmount > _nativeSurplus) {
                // Keep a reference to the amount to redeem for native tokens, a proportion of available surplus in native tokens.
                uint256 _tokenCountToRedeemForNative = PRBMath.mulDiv(
                    _beneficiaryTokenBalance,
                    _nativeSurplus,
                    _nativeSurplus
                        + _toNative(
                            PRBMath.mulDiv(
                                _usdcPayAmount, 10 ** _NATIVE_DECIMALS, 10 ** _usdcToken.decimals()
                            )
                        )
                );
                uint256 _tokenSupply = PRBMath.mulDiv(
                    _beneficiaryTokenBalance,
                    JBConstants.MAX_RESERVED_RATE,
                    JBConstants.MAX_RESERVED_RATE - _metadata.reservedRate
                );
                // Redeem native tokens from the surplus using only the `_beneficiary`'s tokens needed to clear the native token balance.
                _terminal.redeemTokensOf({
                    holder: _beneficiary,
                    projectId: _projectId,
                    count: _tokenCountToRedeemForNative,
                    token: JBTokenList.NATIVE,
                    minReclaimed: 0,
                    beneficiary: payable(_beneficiary),
                    metadata: new bytes(0)
                });

                // Redeem USDC from the surplus using only the `_beneficiary`'s tokens needed to clear the USDC balance.
                _terminal.redeemTokensOf({
                    holder: _beneficiary,
                    projectId: _projectId,
                    count: _beneficiaryTokenBalance - _tokenCountToRedeemForNative,
                    token: address(_usdcToken),
                    minReclaimed: 0,
                    beneficiary: payable(_beneficiary),
                    metadata: new bytes(0)
                });

                _nativeReclaimAmount = PRBMath.mulDiv(
                    PRBMath.mulDiv(
                        _toNative(
                            PRBMath.mulDiv(
                                _usdcPayAmount, 10 ** _NATIVE_DECIMALS, 10 ** _usdcToken.decimals()
                            )
                        ) + _nativeSurplus,
                        _tokenCountToRedeemForNative,
                        _tokenSupply
                    ),
                    _metadata.redemptionRate
                        + PRBMath.mulDiv(
                            _tokenCountToRedeemForNative,
                            JBConstants.MAX_REDEMPTION_RATE - _metadata.redemptionRate,
                            _tokenSupply
                        ),
                    JBConstants.MAX_REDEMPTION_RATE
                );

                uint256 _usdcReclaimAmount = PRBMath.mulDiv(
                    PRBMath.mulDiv(
                        _usdcPayAmount
                            + _toUsd(
                                PRBMath.mulDiv(
                                    _nativeSurplus - _nativeReclaimAmount,
                                    10 ** _usdcToken.decimals(),
                                    10 ** _NATIVE_DECIMALS
                                )
                            ),
                        _beneficiaryTokenBalance - _tokenCountToRedeemForNative,
                        _tokenSupply - _tokenCountToRedeemForNative
                    ),
                    _metadata.redemptionRate
                        + PRBMath.mulDiv(
                            _beneficiaryTokenBalance - _tokenCountToRedeemForNative,
                            JBConstants.MAX_REDEMPTION_RATE - _metadata.redemptionRate,
                            _tokenSupply - _tokenCountToRedeemForNative
                        ),
                    JBConstants.MAX_REDEMPTION_RATE
                );

                assertEq(
                    jbTerminalStore().balanceOf(address(_terminal), _projectId, address(_usdcToken)),
                    _usdcPayAmount - _usdcReclaimAmount
                );

                uint256 _usdcFeeAmount = _usdcReclaimAmount
                    - _usdcReclaimAmount * JBConstants.MAX_FEE / (_terminal.FEE() + JBConstants.MAX_FEE);
                assertEq(_usdcToken.balanceOf(_beneficiary), _usdcReclaimAmount - _usdcFeeAmount);

                // Make sure the fee was paid correctly.
                assertEq(
                    jbTerminalStore().balanceOf(
                        address(_terminal), _FEE_PROJECT_ID, address(_usdcToken)
                    ),
                    _usdcFeeAmount
                );
                assertEq(
                    _usdcToken.balanceOf(address(_terminal)),
                    _usdcPayAmount - _usdcReclaimAmount + _usdcFeeAmount
                );
            } else {
                // Reclaim native tokens from the surplus by redeeming all of the `_beneficiary`'s tokens.
                _terminal.redeemTokensOf({
                    holder: _beneficiary,
                    projectId: _projectId,
                    count: _beneficiaryTokenBalance,
                    token: JBTokenList.NATIVE,
                    minReclaimed: 0,
                    beneficiary: payable(_beneficiary),
                    metadata: new bytes(0)
                });
            }
            // Burn the tokens.
        } else {
            _terminal.redeemTokensOf({
                holder: _beneficiary,
                projectId: _projectId,
                count: _beneficiaryTokenBalance,
                token: address(_usdcToken),
                minReclaimed: 0,
                beneficiary: payable(_beneficiary),
                metadata: new bytes(0)
            });
        }
        vm.stopPrank();

        // Make sure the balance is adjusted by the reclaim amount.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
            _nativeBalance - _nativeReclaimAmount
        );
    }

    // Project 2 accepts native tokens into `_terminal` and USDC into `_terminal2`.
    // Project 1 accepts USDC and native token fees into `_terminal`.
    function testFuzzMultiTerminalPayoutLimits(
        uint224 _nativeCurrencySurplusPayoutLimit,
        uint224 _nativeCurrencyPayoutLimit,
        uint256 _nativePayAmount,
        uint224 _usdCurrencySurplusPayoutLimit,
        uint224 _usdCurrencyPayoutLimit,
        uint256 _usdcPayAmount
    ) public {
        // Make sure the amount of native tokens to pay is bounded.
        _nativePayAmount = bound(_nativePayAmount, 0, 1_000_000 * 10 ** _NATIVE_DECIMALS);
        _usdcPayAmount = bound(_usdcPayAmount, 0, 1_000_000 * 10 ** _usdcToken.decimals());
        _usdCurrencyPayoutLimit = uint224(
            bound(
                _usdCurrencyPayoutLimit,
                0,
                type(uint224).max / 10 ** (_NATIVE_DECIMALS - _usdcToken.decimals())
            )
        );

        // Make sure the values don't overflow the registry.
        unchecked {
            vm.assume(
                _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                    >= _nativeCurrencySurplusPayoutLimit
                    && _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit
                        >= _nativeCurrencyPayoutLimit
            );
            vm.assume(
                _usdCurrencySurplusPayoutLimit + _usdCurrencyPayoutLimit
                    >= _usdCurrencySurplusPayoutLimit
                    && _usdCurrencySurplusPayoutLimit + _usdCurrencyPayoutLimit
                        >= _usdCurrencyPayoutLimit
            );
        }

        {
            // Package up the limits for the given terminal.
            JBFundAccessLimitGroup[] memory _fundAccessLimitGroup = new JBFundAccessLimitGroup[](2);

            // Specify payout limits.
            JBCurrencyAmount[] memory _payoutLimits1 = new JBCurrencyAmount[](1);
            JBCurrencyAmount[] memory _payoutLimits2 = new JBCurrencyAmount[](1);
            _payoutLimits1[0] = JBCurrencyAmount({
                amount: _nativeCurrencyPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });
            _payoutLimits2[0] = JBCurrencyAmount({
                amount: _usdCurrencyPayoutLimit,
                currency: uint32(uint160(address(_usdcToken)))
            });

            // Specify surplus payout limits.
            JBCurrencyAmount[] memory _surplusPayoutLimits1 = new JBCurrencyAmount[](1);
            JBCurrencyAmount[] memory _surplusPayoutLimits2 = new JBCurrencyAmount[](1);
            _surplusPayoutLimits1[0] = JBCurrencyAmount({
                amount: _nativeCurrencySurplusPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE))
            });
            _surplusPayoutLimits2[0] = JBCurrencyAmount({
                amount: _usdCurrencySurplusPayoutLimit,
                currency: uint32(uint160(address(_usdcToken)))
            });

            _fundAccessLimitGroup[0] = JBFundAccessLimitGroup({
                terminal: address(_terminal),
                token: JBTokenList.NATIVE,
                payoutLimits: _payoutLimits1,
                surplusPayoutLimits: _surplusPayoutLimits1
            });

            _fundAccessLimitGroup[1] = JBFundAccessLimitGroup({
                terminal: address(_terminal2),
                token: address(_usdcToken),
                payoutLimits: _payoutLimits2,
                surplusPayoutLimits: _surplusPayoutLimits2
            });

            // Package up the ruleset configuration.
            JBRulesetConfig[] memory _rulesetConfigurations = new JBRulesetConfig[](1);
            _rulesetConfigurations[0].mustStartAtOrAfter = 0;
            _rulesetConfigurations[0].data = _data;
            _rulesetConfigurations[0].metadata = _metadata;
            _rulesetConfigurations[0].splitGroups = new JBSplitGroup[](0);
            _rulesetConfigurations[0].fundAccessLimitGroups = _fundAccessLimitGroup;

            JBTerminalConfig[] memory _terminalConfigurations1 = new JBTerminalConfig[](1);
            JBTerminalConfig[] memory _terminalConfigurations2 = new JBTerminalConfig[](2);
            JBAccountingContextConfig[] memory _accountingContextConfigs1 =
                new JBAccountingContextConfig[](2);
            JBAccountingContextConfig[] memory _accountingContextConfigs2 =
                new JBAccountingContextConfig[](1);
            JBAccountingContextConfig[] memory _accountingContextConfigs3 =
                new JBAccountingContextConfig[](1);
            _accountingContextConfigs1[0] = JBAccountingContextConfig({
                token: JBTokenList.NATIVE,
                standard: JBTokenStandards.NATIVE
            });
            _accountingContextConfigs1[1] = JBAccountingContextConfig({
                token: address(_usdcToken),
                standard: JBTokenStandards.ERC20
            });
            _accountingContextConfigs2[0] = JBAccountingContextConfig({
                token: JBTokenList.NATIVE,
                standard: JBTokenStandards.NATIVE
            });
            _accountingContextConfigs3[0] = JBAccountingContextConfig({
                token: address(_usdcToken),
                standard: JBTokenStandards.ERC20
            });

            // Fee takes USDC and native token in same terminal.
            _terminalConfigurations1[0] = JBTerminalConfig({
                terminal: _terminal,
                accountingContextConfigs: _accountingContextConfigs1
            });
            _terminalConfigurations2[0] = JBTerminalConfig({
                terminal: _terminal,
                accountingContextConfigs: _accountingContextConfigs2
            });
            _terminalConfigurations2[1] = JBTerminalConfig({
                terminal: _terminal2,
                accountingContextConfigs: _accountingContextConfigs3
            });

            // Create a first project to collect fees.
            _controller.launchProjectFor({
                owner: address(420), // Random.
                projectMetadata: "whatever",
                rulesetConfigurations: _rulesetConfigurations, // Use the same ruleset configurations.
                terminalConfigurations: _terminalConfigurations1, // Set terminals to receive fees.
                memo: ""
            });

            // Create the project to test.
            _projectId = _controller.launchProjectFor({
                owner: _projectOwner,
                projectMetadata: "myIPFSHash",
                rulesetConfigurations: _rulesetConfigurations,
                terminalConfigurations: _terminalConfigurations2,
                memo: ""
            });
        }

        // Add a price feed to convert from native token to USD currencies.
        {
            vm.startPrank(_projectOwner);
            MockPriceFeed _priceFeedNativeUsd =
                new MockPriceFeed(_USD_PRICE_PER_NATIVE, _PRICE_FEED_DECIMALS);
            vm.label(address(_priceFeedNativeUsd), "Mock Price Feed Native-USDC");

            _prices.addPriceFeedFor({
                projectId: 0,
                pricingCurrency: uint32(uint160(address(_usdcToken))),
                unitCurrency: uint32(uint160(JBTokenList.NATIVE)),
                priceFeed: _priceFeedNativeUsd
            });

            vm.stopPrank();
        }

        // Make a payment to the project to give it a starting balance. Send the tokens to the `_beneficiary`.
        _terminal.pay{value: _nativePayAmount}({
            projectId: _projectId,
            amount: _nativePayAmount,
            token: JBTokenList.NATIVE,
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Make sure the beneficiary got the expected number of tokens from the native token payment.
        uint256 _beneficiaryTokenBalance = _unreservedPortion(
            PRBMath.mulDiv(_nativePayAmount, _data.weight, 10 ** _NATIVE_DECIMALS)
        );
        assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);
        // Mint USDC to this contract.
        _usdcToken.mint(address(this), _usdcPayAmount);

        // Allow the terminal to spend the USDC.
        _usdcToken.approve(address(_terminal2), _usdcPayAmount);

        // Make a payment to the project to give it a starting balance. Send the tokens to the `_beneficiary`.
        _terminal2.pay({
            projectId: _projectId,
            amount: _usdcPayAmount,
            token: address(_usdcToken),
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            memo: "",
            metadata: new bytes(0)
        });

        // Make sure the terminal holds the full native token balance.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
            _nativePayAmount
        );
        // Make sure the USDC is accounted for.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal2), _projectId, address(_usdcToken)),
            _usdcPayAmount
        );
        assertEq(_usdcToken.balanceOf(address(_terminal2)), _usdcPayAmount);

        {
            // Convert the USD amount to a native token amount, by way of the current weight used for issuance.
            uint256 _usdWeightedPayAmountConvertedToNative = PRBMath.mulDiv(
                _usdcPayAmount,
                _data.weight,
                PRBMath.mulDiv(
                    _USD_PRICE_PER_NATIVE, 10 ** _usdcToken.decimals(), 10 ** _PRICE_FEED_DECIMALS
                )
            );

            // Make sure the beneficiary got the expected number of tokens from the USDC payment.
            _beneficiaryTokenBalance += _unreservedPortion(_usdWeightedPayAmountConvertedToNative);
            assertEq(_tokens.totalBalanceOf(_beneficiary, _projectId), _beneficiaryTokenBalance);
        }

        // Revert if there's no surplus payout limit for the native token.
        if (_nativeCurrencySurplusPayoutLimit == 0) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_CONTROLLER_SURPLUS_PAYOUT_LIMIT()"));
        } else if (
            _nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit > _nativePayAmount
        ) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
        }

        // Use the full surplus payout limit for the native token.
        vm.prank(_projectOwner);
        _terminal.payoutSurplusOf({
            projectId: _projectId,
            amount: _nativeCurrencySurplusPayoutLimit,
            currency: uint32(uint160(JBTokenList.NATIVE)),
            token: JBTokenList.NATIVE,
            minReturnedTokens: 0,
            beneficiary: payable(_beneficiary),
            memo: "MEMO"
        });

        // Keep a reference to the beneficiary's native token balance.
        uint256 _beneficiaryNativeBalance;

        // Check the collected balance if one is expected.
        if (_nativeCurrencySurplusPayoutLimit + _nativeCurrencyPayoutLimit <= _nativePayAmount) {
            // Make sure the beneficiary received the funds and that they are no longer in the terminal.
            _beneficiaryNativeBalance = PRBMath.mulDiv(
                _nativeCurrencySurplusPayoutLimit,
                JBConstants.MAX_FEE,
                JBConstants.MAX_FEE + _terminal.FEE()
            );
            assertEq(_beneficiary.balance, _beneficiaryNativeBalance);
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                _nativePayAmount - _nativeCurrencySurplusPayoutLimit
            );

            // Make sure the fee was paid correctly.
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE),
                _nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance
            );
            assertEq(address(_terminal).balance, _nativePayAmount - _beneficiaryNativeBalance);

            // Make sure the beneficiary got the expected number of tokens.
            assertEq(
                _tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID),
                _unreservedPortion(
                    PRBMath.mulDiv(
                        _nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance,
                        _data.weight,
                        10 ** _NATIVE_DECIMALS
                    )
                )
            );
        } else {
            // Set the surplus payout limit for the native token to 0 if it wasn't used.
            _nativeCurrencySurplusPayoutLimit = 0;
        }

        // Revert if there's no surplus payout limit for the native token.
        if (_usdCurrencySurplusPayoutLimit == 0) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_CONTROLLER_SURPLUS_PAYOUT_LIMIT()"));
            // Revert if the USD surplus payout limit resolved to native tokens is greater than 0, and there is sufficient surplus to pull from including what was already pulled from.
        } else if (_usdCurrencySurplusPayoutLimit + _usdCurrencyPayoutLimit > _usdcPayAmount) {
            vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
        }

        // Use the full surplus payout limit for the native token.
        vm.prank(_projectOwner);
        _terminal2.payoutSurplusOf({
            projectId: _projectId,
            amount: _usdCurrencySurplusPayoutLimit,
            currency: uint32(uint160(address(_usdcToken))),
            token: address(_usdcToken),
            minReturnedTokens: 0,
            beneficiary: payable(_beneficiary),
            memo: "MEMO"
        });

        // Keep a reference to the beneficiary's USDC balance.
        uint256 _beneficiaryUsdcBalance;

        // Check the collected balance if one is expected.
        if (_usdCurrencySurplusPayoutLimit + _usdCurrencyPayoutLimit <= _usdcPayAmount) {
            // Make sure the beneficiary received the funds and that they are no longer in the terminal.
            _beneficiaryUsdcBalance += PRBMath.mulDiv(
                _usdCurrencySurplusPayoutLimit,
                JBConstants.MAX_FEE,
                JBConstants.MAX_FEE + _terminal.FEE()
            );
            assertEq(_usdcToken.balanceOf(_beneficiary), _beneficiaryUsdcBalance);
            assertEq(
                jbTerminalStore().balanceOf(address(_terminal2), _projectId, address(_usdcToken)),
                _usdcPayAmount - _usdCurrencySurplusPayoutLimit
            );

            // Make sure the fee was paid correctly.
            assertEq(
                jbTerminalStore().balanceOf(
                    address(_terminal), _FEE_PROJECT_ID, address(_usdcToken)
                ),
                _usdCurrencySurplusPayoutLimit - _beneficiaryUsdcBalance
            );
            assertEq(
                _usdcToken.balanceOf(address(_terminal2)),
                _usdcPayAmount - _usdCurrencySurplusPayoutLimit
            );
            assertEq(
                _usdcToken.balanceOf(address(_terminal)),
                _usdCurrencySurplusPayoutLimit - _beneficiaryUsdcBalance
            );

            // Make sure the beneficiary got the expected number of tokens.
            assertEq(
                _tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID),
                _unreservedPortion(
                    PRBMath.mulDiv(
                        _nativeCurrencySurplusPayoutLimit
                            + _toNative(
                                PRBMath.mulDiv(
                                    _usdCurrencySurplusPayoutLimit,
                                    10 ** _NATIVE_DECIMALS,
                                    10 ** _usdcToken.decimals()
                                )
                            ) - _beneficiaryNativeBalance
                            - _toNative(
                                PRBMath.mulDiv(
                                    _beneficiaryUsdcBalance,
                                    10 ** _NATIVE_DECIMALS,
                                    10 ** _usdcToken.decimals()
                                )
                            ),
                        _data.weight,
                        10 ** _NATIVE_DECIMALS
                    )
                )
            );
        } else {
            // Set the surplus payout limit for the native token to 0 if it wasn't used.
            _usdCurrencySurplusPayoutLimit = 0;
        }

        // Payout limits
        {
            // Revert if the payout limit is greater than the balance.
            if (_nativeCurrencyPayoutLimit > _nativePayAmount) {
                vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
                // Revert if there's no payout limit.
            } else if (_nativeCurrencyPayoutLimit == 0) {
                vm.expectRevert(abi.encodeWithSignature("PAYOUT_LIMIT_EXCEEDED()"));
            }

            // Pay out native tokens up to the payout limit. Since `splits[]` is empty, everything goes to project owner.
            _terminal.sendPayoutsOf({
                projectId: _projectId,
                amount: _nativeCurrencyPayoutLimit,
                currency: uint32(uint160(JBTokenList.NATIVE)),
                token: JBTokenList.NATIVE,
                minReturnedTokens: 0
            });

            uint256 _projectOwnerNativeBalance;

            // Check the received payout if one is expected.
            if (_nativeCurrencyPayoutLimit <= _nativePayAmount && _nativeCurrencyPayoutLimit != 0) {
                // Make sure the project owner received the funds that were paid out.
                _projectOwnerNativeBalance = (_nativeCurrencyPayoutLimit * JBConstants.MAX_FEE)
                    / (_terminal.FEE() + JBConstants.MAX_FEE);
                assertEq(_projectOwner.balance, _projectOwnerNativeBalance);
                assertEq(
                    jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
                    _nativePayAmount - _nativeCurrencySurplusPayoutLimit
                        - _nativeCurrencyPayoutLimit
                );

                // Make sure the fee was paid correctly.
                assertEq(
                    jbTerminalStore().balanceOf(
                        address(_terminal), _FEE_PROJECT_ID, JBTokenList.NATIVE
                    ),
                    _nativeCurrencySurplusPayoutLimit - _beneficiaryNativeBalance
                        + _nativeCurrencyPayoutLimit - _projectOwnerNativeBalance
                );
                assertEq(
                    address(_terminal).balance,
                    _nativePayAmount - _beneficiaryNativeBalance - _projectOwnerNativeBalance
                );

                // Make sure the project owner got the expected number of tokens.
                // assertEq(_tokens.totalBalanceOf(_projectOwner, _FEE_PROJECT_ID), _unreservedPortion(PRBMath.mulDiv(_nativeCurrencySurplusPayoutLimit + _toNative(_usdCurrencySurplusPayoutLimit) - _beneficiaryNativeBalance + _nativeCurrencyPayoutLimit - _projectOwnerNativeBalance, _data.weight, 10 ** _NATIVE_DECIMALS)));
            }

            // Revert if the payout limit is greater than the balance.
            if (_usdCurrencyPayoutLimit > _usdcPayAmount) {
                vm.expectRevert(abi.encodeWithSignature("INADEQUATE_TERMINAL_STORE_BALANCE()"));
                // Revert if there's no payout limit.
            } else if (_usdCurrencyPayoutLimit == 0) {
                vm.expectRevert(abi.encodeWithSignature("PAYOUT_LIMIT_EXCEEDED()"));
            }

            // Pay out native tokens up to the payout limit. Since `splits[]` is empty, everything goes to project owner.
            _terminal2.sendPayoutsOf({
                projectId: _projectId,
                amount: _usdCurrencyPayoutLimit,
                currency: uint32(uint160(address(_usdcToken))),
                token: address(_usdcToken),
                minReturnedTokens: 0
            });

            uint256 _projectOwnerUsdcBalance;

            // Check the received payout if one is expected.
            if (_usdCurrencyPayoutLimit <= _usdcPayAmount && _usdCurrencyPayoutLimit != 0) {
                // Make sure the project owner received the funds that were paid out.
                _projectOwnerUsdcBalance = (_usdCurrencyPayoutLimit * JBConstants.MAX_FEE)
                    / (_terminal.FEE() + JBConstants.MAX_FEE);
                assertEq(_usdcToken.balanceOf(_projectOwner), _projectOwnerUsdcBalance);
                assertEq(
                    jbTerminalStore().balanceOf(
                        address(_terminal2), _projectId, address(_usdcToken)
                    ),
                    _usdcPayAmount - _usdCurrencySurplusPayoutLimit - _usdCurrencyPayoutLimit
                );

                // Make sure the fee was paid correctly.
                assertEq(
                    jbTerminalStore().balanceOf(
                        address(_terminal), _FEE_PROJECT_ID, address(_usdcToken)
                    ),
                    _usdCurrencySurplusPayoutLimit - _beneficiaryUsdcBalance
                        + _usdCurrencyPayoutLimit - _projectOwnerUsdcBalance
                );
                assertEq(
                    _usdcToken.balanceOf(address(_terminal2)),
                    _usdcPayAmount - _usdCurrencySurplusPayoutLimit - _usdCurrencyPayoutLimit
                );
                assertEq(
                    _usdcToken.balanceOf(address(_terminal)),
                    _usdCurrencySurplusPayoutLimit + _usdCurrencyPayoutLimit
                        - _beneficiaryUsdcBalance - _projectOwnerUsdcBalance
                );
            }
        }

        // Keep a reference to the remaining native token surplus.
        uint256 _nativeSurplus = _nativeCurrencyPayoutLimit + _nativeCurrencySurplusPayoutLimit
            >= _nativePayAmount
            ? 0
            : _nativePayAmount - _nativeCurrencyPayoutLimit - _nativeCurrencySurplusPayoutLimit;

        uint256 _usdcSurplus = _usdCurrencyPayoutLimit + _usdCurrencySurplusPayoutLimit
            >= _usdcPayAmount
            ? 0
            : _usdcPayAmount - _usdCurrencyPayoutLimit - _usdCurrencySurplusPayoutLimit;

        // Keep a reference to the remaining native token balance.
        uint256 _usdcBalanceInTerminal = _usdcPayAmount - _usdCurrencySurplusPayoutLimit;

        if (_usdCurrencyPayoutLimit <= _usdcPayAmount) {
            _usdcBalanceInTerminal -= _usdCurrencyPayoutLimit;
        }

        assertEq(_usdcToken.balanceOf(address(_terminal2)), _usdcBalanceInTerminal);

        // Make sure the total token supply is correct.
        assertEq(
            jbController().totalTokenSupplyWithReservedTokensOf(_projectId),
            PRBMath.mulDiv(
                _beneficiaryTokenBalance,
                JBConstants.MAX_RESERVED_RATE,
                JBConstants.MAX_RESERVED_RATE - _metadata.reservedRate
            )
        );

        // Keep a reference to the amount of native tokens being reclaimed.
        uint256 _nativeReclaimAmount;

        vm.startPrank(_beneficiary);

        // If there's native token surplus.
        if (
            _nativeSurplus
                + _toNative(
                    PRBMath.mulDiv(_usdcSurplus, 10 ** _NATIVE_DECIMALS, 10 ** _usdcToken.decimals())
                ) > 0
        ) {
            // Get the expected amount reclaimed.
            _nativeReclaimAmount = PRBMath.mulDiv(
                PRBMath.mulDiv(
                    _nativeSurplus
                        + _toNative(
                            PRBMath.mulDiv(
                                _usdcSurplus, 10 ** _NATIVE_DECIMALS, 10 ** _usdcToken.decimals()
                            )
                        ),
                    _beneficiaryTokenBalance,
                    PRBMath.mulDiv(
                        _beneficiaryTokenBalance,
                        JBConstants.MAX_RESERVED_RATE,
                        JBConstants.MAX_RESERVED_RATE - _metadata.reservedRate
                    )
                ),
                _metadata.redemptionRate
                    + PRBMath.mulDiv(
                        _beneficiaryTokenBalance,
                        JBConstants.MAX_REDEMPTION_RATE - _metadata.redemptionRate,
                        PRBMath.mulDiv(
                            _beneficiaryTokenBalance,
                            JBConstants.MAX_RESERVED_RATE,
                            JBConstants.MAX_RESERVED_RATE - _metadata.reservedRate
                        )
                    ),
                JBConstants.MAX_REDEMPTION_RATE
            );

            // If there is more to reclaim than there are native tokens in the tank.
            if (_nativeReclaimAmount > _nativeSurplus) {
                uint256 _usdcReclaimAmount;
                {
                    // Keep a reference to the amount of project tokens to redeem for native tokens, a proportion of available native token surplus.
                    uint256 _tokenCountToRedeemForNative = PRBMath.mulDiv(
                        _beneficiaryTokenBalance,
                        _nativeSurplus,
                        _nativeSurplus
                            + _toNative(
                                PRBMath.mulDiv(
                                    _usdcSurplus, 10 ** _NATIVE_DECIMALS, 10 ** _usdcToken.decimals()
                                )
                            )
                    );
                    uint256 _tokenSupply = PRBMath.mulDiv(
                        _beneficiaryTokenBalance,
                        JBConstants.MAX_RESERVED_RATE,
                        JBConstants.MAX_RESERVED_RATE - _metadata.reservedRate
                    );
                    // Redeem native tokens from the surplus using only the `_beneficiary`'s tokens needed to clear the native token balance.
                    _terminal.redeemTokensOf({
                        holder: _beneficiary,
                        projectId: _projectId,
                        count: _tokenCountToRedeemForNative,
                        token: JBTokenList.NATIVE,
                        minReclaimed: 0,
                        beneficiary: payable(_beneficiary),
                        metadata: new bytes(0)
                    });

                    // Redeem USDC from the surplus using only the `_beneficiary`'s tokens needed to clear the USDC balance.
                    _terminal2.redeemTokensOf({
                        holder: _beneficiary,
                        projectId: _projectId,
                        count: _beneficiaryTokenBalance - _tokenCountToRedeemForNative,
                        token: address(_usdcToken),
                        minReclaimed: 0,
                        beneficiary: payable(_beneficiary),
                        metadata: new bytes(0)
                    });

                    _nativeReclaimAmount = PRBMath.mulDiv(
                        PRBMath.mulDiv(
                            _nativeSurplus
                                + _toNative(
                                    PRBMath.mulDiv(
                                        _usdcSurplus,
                                        10 ** _NATIVE_DECIMALS,
                                        10 ** _usdcToken.decimals()
                                    )
                                ),
                            _tokenCountToRedeemForNative,
                            _tokenSupply
                        ),
                        _metadata.redemptionRate
                            + PRBMath.mulDiv(
                                _tokenCountToRedeemForNative,
                                JBConstants.MAX_REDEMPTION_RATE - _metadata.redemptionRate,
                                _tokenSupply
                            ),
                        JBConstants.MAX_REDEMPTION_RATE
                    );
                    _usdcReclaimAmount = PRBMath.mulDiv(
                        PRBMath.mulDiv(
                            _usdcSurplus
                                + _toUsd(
                                    PRBMath.mulDiv(
                                        _nativeSurplus - _nativeReclaimAmount,
                                        10 ** _usdcToken.decimals(),
                                        10 ** _NATIVE_DECIMALS
                                    )
                                ),
                            _beneficiaryTokenBalance - _tokenCountToRedeemForNative,
                            _tokenSupply - _tokenCountToRedeemForNative
                        ),
                        _metadata.redemptionRate
                            + PRBMath.mulDiv(
                                _beneficiaryTokenBalance - _tokenCountToRedeemForNative,
                                JBConstants.MAX_REDEMPTION_RATE - _metadata.redemptionRate,
                                _tokenSupply - _tokenCountToRedeemForNative
                            ),
                        JBConstants.MAX_REDEMPTION_RATE
                    );
                }

                assertEq(
                    jbTerminalStore().balanceOf(
                        address(_terminal2), _projectId, address(_usdcToken)
                    ),
                    _usdcSurplus - _usdcReclaimAmount
                );

                uint256 _usdcFeeAmount = _usdcReclaimAmount
                    - _usdcReclaimAmount * JBConstants.MAX_FEE / (_terminal.FEE() + JBConstants.MAX_FEE);

                _beneficiaryUsdcBalance += _usdcReclaimAmount - _usdcFeeAmount;
                assertEq(_usdcToken.balanceOf(_beneficiary), _beneficiaryUsdcBalance);

                assertEq(
                    _usdcToken.balanceOf(address(_terminal2)),
                    _usdcBalanceInTerminal - _usdcReclaimAmount
                );

                // Only the fees left.
                assertEq(
                    _usdcToken.balanceOf(address(_terminal)),
                    _usdcPayAmount - _usdcToken.balanceOf(address(_terminal2))
                        - _usdcToken.balanceOf(_beneficiary) - _usdcToken.balanceOf(_projectOwner)
                );
            } else {
                // Reclaim native tokens from the surplus by redeeming all of the `_beneficiary`'s tokens.
                _terminal.redeemTokensOf({
                    holder: _beneficiary,
                    projectId: _projectId,
                    count: _beneficiaryTokenBalance,
                    token: JBTokenList.NATIVE,
                    minReclaimed: 0,
                    beneficiary: payable(_beneficiary),
                    metadata: new bytes(0)
                });
            }
            // Burn the tokens.
        } else {
            _terminal2.redeemTokensOf({
                holder: _beneficiary,
                projectId: _projectId,
                count: _beneficiaryTokenBalance,
                token: address(_usdcToken),
                minReclaimed: 0,
                beneficiary: payable(_beneficiary),
                metadata: new bytes(0)
            });
        }
        vm.stopPrank();

        // Keep a reference to the remaining native token balance.
        uint256 _projectNativeBalance = _nativePayAmount - _nativeCurrencySurplusPayoutLimit;
        if (_nativeCurrencyPayoutLimit <= _nativePayAmount) {
            _projectNativeBalance -= _nativeCurrencyPayoutLimit;
        }

        // Make sure the balance is adjusted by the reclaim amount.
        assertEq(
            jbTerminalStore().balanceOf(address(_terminal), _projectId, JBTokenList.NATIVE),
            _projectNativeBalance - _nativeReclaimAmount
        );
    }

    function _toNative(uint256 _usdVal) internal pure returns (uint256) {
        return PRBMath.mulDiv(_usdVal, 10 ** _PRICE_FEED_DECIMALS, _USD_PRICE_PER_NATIVE);
    }

    function _toUsd(uint256 _nativeVal) internal pure returns (uint256) {
        return PRBMath.mulDiv(_nativeVal, _USD_PRICE_PER_NATIVE, 10 ** _PRICE_FEED_DECIMALS);
    }

    function _unreservedPortion(uint256 _fullPortion) internal view returns (uint256) {
        return PRBMath.mulDiv(
            _fullPortion,
            JBConstants.MAX_RESERVED_RATE - _metadata.reservedRate,
            JBConstants.MAX_RESERVED_RATE
        );
    }
}
