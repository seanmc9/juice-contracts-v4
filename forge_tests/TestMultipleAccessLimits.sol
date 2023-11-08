// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";
import {MockPriceFeed} from "./mock/MockPriceFeed.sol";

contract TestMultipleDistLimits_Local is TestBaseWorkflow {
    uint256 private _ethCurrency; 
    uint256 private _usdCurrency; 
    IJBController3_1 private _controller;
    IJBPayoutRedemptionPaymentTerminal3_1 private _terminal3_2;
    IJBPrices private _prices;
    JBTokenStore private _tokenStore;
    JBSingleTokenPaymentTerminalStore3_1_1 private _jbPaymentTerminalStore3_1_1;
    JBProjectMetadata private _projectMetadata;
    JBFundingCycleData private _data;
    JBFundingCycleMetadata _metadata;
    JBGroupedSplits[] private _groupedSplits;
    IJBPaymentTerminal[] private _terminals;
    address private _projectOwner;
    address private _beneficiary;

    function setUp() public override {
        super.setUp();

        _ethCurrency = jbLibraries().ETH();
        _usdCurrency = jbLibraries().USD();
        _controller = jbController();
        _projectOwner = multisig();
        _beneficiary = beneficiary();
        _prices = jbPrices();
        _jbPaymentTerminalStore3_1_1 = jbPaymentTerminalStore();
        _terminal3_2 = new JBETHPaymentTerminal3_1_2(
            jbOperatorStore(),
            jbProjects(),
            jbDirectory(),
            jbSplitsStore(),
            _prices,
            address(_jbPaymentTerminalStore3_1_1),
            _projectOwner
        );
        _tokenStore = jbTokenStore();
        _projectMetadata = JBProjectMetadata({content: "myIPFSHash", domain: 1});
        _data = JBFundingCycleData({
            duration: 0,
            weight: 1000 * 10 ** 18,
            discountRate: 0,
            ballot: IJBFundingCycleBallot(address(0))
        });
        _metadata = JBFundingCycleMetadata({
            global: JBGlobalFundingCycleMetadata({
                allowSetTerminals: false,
                allowSetController: false,
                pauseTransfers: false
            }),
            reservedRate: 0,
            redemptionRate: 0,
            baseCurrency: 1,
            pausePay: false,
            pauseDistributions: false,
            pauseRedeem: false,
            pauseBurn: false,
            allowMinting: false,
            allowTerminalMigration: false,
            allowControllerMigration: false,
            holdFees: false,
            preferClaimedTokenOverride: false,
            useTotalOverflowForRedemptions: false,
            useDataSourceForPay: false,
            useDataSourceForRedeem: false,
            dataSource: address(0),
            metadata: 0
        });

        _terminals.push(_terminal3_2);
    }

    function testAccessConstraintsDelineation() external {
        uint256 _ethPayAmount = 1.5 ether;
        uint256 _ethDistributionLimit = 1 ether;
        uint256 _ethPricePerUsd = 0.0005 * 10**18; // 1/2000
        // More than the treasury will have available.
        uint256 _usdDistributionLimit = PRBMath.mulDiv(1 ether, 10**18, _ethPricePerUsd);

        // Package up fund access constraints
        JBFundAccessConstraints[] memory _fundAccessConstraints = new JBFundAccessConstraints[](1);
        JBCurrencyAmount[] memory _distributionLimits = new JBCurrencyAmount[](2);
        JBCurrencyAmount[] memory _overflowAllowances = new JBCurrencyAmount[](1);
        
        _distributionLimits[0] = JBCurrencyAmount({
            value: _ethDistributionLimit,
            currency: _ethCurrency
        });
        _distributionLimits[1] = JBCurrencyAmount({
            value: _usdDistributionLimit,
            currency: _usdCurrency
        });
        _overflowAllowances[0] = JBCurrencyAmount({
            value: 1,
            currency: 1
        });
        _fundAccessConstraints[0] = 
            JBFundAccessConstraints({
                terminal: _terminal3_2,
                token: jbLibraries().ETHToken(),
                distributionLimits: _distributionLimits,
                overflowAllowances: _overflowAllowances
            });

        // Package up cycle config.
        JBFundingCycleConfiguration[] memory _cycleConfig = new JBFundingCycleConfiguration[](1);
        _cycleConfig[0].mustStartAtOrAfter = 0;
        _cycleConfig[0].data = _data;
        _cycleConfig[0].metadata = _metadata;
        _cycleConfig[0].groupedSplits = _groupedSplits;
        _cycleConfig[0].fundAccessConstraints = _fundAccessConstraints;

        // dummy
        _controller.launchProjectFor({
            owner: address(420), //random
            projectMetadata: _projectMetadata,
            configurations: _cycleConfig,
            terminals: _terminals,
            memo: ""
        });

        uint256 _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectMetadata: _projectMetadata,
            configurations: _cycleConfig,
            terminals: _terminals,
            memo: ""
        });

        vm.startPrank(_projectOwner);
        MockPriceFeed _priceFeedEthUsd = new MockPriceFeed(_ethPricePerUsd, 18);
        vm.label(address(_priceFeedEthUsd), "MockPrice Feed MyToken-ETH");

        _prices.addFeedFor({
            projectId: _projectId,
            currency: _ethCurrency, 
            base: _usdCurrency, 
            priceFeed: _priceFeedEthUsd
        });

        vm.stopPrank();

        _terminal3_2.pay{value: _ethPayAmount}({
            projectId: _projectId,
            amount: _ethPayAmount,
            token: address(0), // unused.
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            preferClaimedTokens: false,
            memo: "Take my money!",
            metadata: new bytes(0)
        });

        uint256 initTerminalBalance = address(_terminal3_2).balance;

        // Make sure the beneficiary has a balance of JBTokens.
        assertEq(_tokenStore.balanceOf(_beneficiary, _projectId), PRBMathUD60x18.mul(_ethPayAmount, _data.weight));

        // First dist meets our ETH limit
        _terminal3_2.distributePayoutsOf({
            projectId: _projectId,
            amount: _ethDistributionLimit,
            currency: _ethCurrency,
            token: address(0), // unused
            minReturnedTokens: 0,
            metadata: "lfg"
        });

        // Make sure the balance has changed, accounting for the fee that stays.
        assertEq(
            address(_terminal3_2).balance,
            initTerminalBalance - PRBMath.mulDiv(_distributionLimits[0].value, jbLibraries().MAX_FEE(), jbLibraries().MAX_FEE() + _terminal3_2.fee())
        );

        // Price for the amount (in USD) that is distributable based on the terminals current balance
        uint256 _usdDistributableAmount = PRBMath.mulDiv(
            _ethPayAmount - _ethDistributionLimit, // ETH value
            10**18, // Use _MAX_FIXED_POINT_FIDELITY to keep as much of the `_amount.value`'s fidelity as possible when converting.
            _prices.priceFor({
                projectId: _projectId, 
                currency: _ethCurrency, 
                base: _usdCurrency, 
                decimals: 18
            })
        );

        // Confirm that anything over the _distributableAmount will fail via paymentterminalstore3_2
        // This doesn't work when expecting & calling distributePayoutsOf bc of chained calls
        vm.prank(address(_terminal3_2));
        vm.expectRevert(abi.encodeWithSignature("INADEQUATE_PAYMENT_TERMINAL_STORE_BALANCE()"));
        // add 10000 to make up for the fidelity difference in prices. (0.0005/1)
        _jbPaymentTerminalStore3_1_1.recordDistributionFor(_projectId, _usdDistributableAmount + 10000, _usdCurrency);

        // Should succeed with _distributableAmount
        _terminal3_2.distributePayoutsOf({
            projectId: _projectId,
            amount: _usdDistributableAmount,
            currency: _usdCurrency,
            token: address(0), // token
            minReturnedTokens: 0,
            metadata: "lfg"
        });

        // Pay in another allotment.
        vm.deal(_beneficiary, _ethPayAmount);
        vm.prank(_beneficiary);

        _terminal3_2.pay{value:_ethPayAmount}({
            projectId: _projectId,
            amount: _ethPayAmount,
            token: address(0), // unused 
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            preferClaimedTokens: false,
            memo: "Take my money!",
            metadata: new bytes(0)
        });

        // Trying to distribute via our ETH distLimit will fail (currency is ETH or 1)
        vm.prank(address(_terminal3_2));
        vm.expectRevert(abi.encodeWithSignature("DISTRIBUTION_AMOUNT_LIMIT_REACHED()"));
        _jbPaymentTerminalStore3_1_1.recordDistributionFor(_projectId, 1, _ethCurrency);

        // But distribution via USD limit will succeed 
        _terminal3_2.distributePayoutsOf({
            projectId: _projectId,
            amount: _usdDistributableAmount,
            currency: _usdCurrency,
            token: address(0), //token (unused)
            minReturnedTokens: 0,
            metadata: "lfg"
        });
    }

    function testFuzzedInvalidAllowanceCurrencyOrdering(uint24 ALLOWCURRENCY) external {
        JBFundAccessConstraints[] memory _fundAccessConstraints = new JBFundAccessConstraints[](1);
        JBCurrencyAmount[] memory _distributionLimits = new JBCurrencyAmount[](1);
        JBCurrencyAmount[] memory _overflowAllowances = new JBCurrencyAmount[](2);

        _distributionLimits[0] = JBCurrencyAmount({
            value: 1,
            currency: _ethCurrency
        });

        _overflowAllowances[0] = JBCurrencyAmount({
            value: 1,
            currency: ALLOWCURRENCY
        });

        _overflowAllowances[1] = JBCurrencyAmount({
            value: 1,
            currency: ALLOWCURRENCY == 0 ? 0 : ALLOWCURRENCY - 1
        });

        _fundAccessConstraints[0] = 
            JBFundAccessConstraints({
                terminal: _terminal3_2,
                token: jbLibraries().ETHToken(),
                distributionLimits: _distributionLimits,
                overflowAllowances: _overflowAllowances
            });

        JBFundingCycleConfiguration[] memory _cycleConfig = new JBFundingCycleConfiguration[](1);

        _cycleConfig[0].mustStartAtOrAfter = 0;
        _cycleConfig[0].data = _data;
        _cycleConfig[0].metadata = _metadata;
        _cycleConfig[0].groupedSplits = _groupedSplits;
        _cycleConfig[0].fundAccessConstraints = _fundAccessConstraints;

        _projectOwner = multisig();

        vm.prank(_projectOwner);

        vm.expectRevert(abi.encodeWithSignature("INVALID_OVERFLOW_ALLOWANCE_CURRENCY_ORDERING()"));
        
        _controller.launchProjectFor({
            owner: _projectOwner,
            projectMetadata: _projectMetadata,
            configurations: _cycleConfig,
            terminals: _terminals,
            memo: ""
        });
    }

    function testFuzzedInvalidDistCurrencyOrdering(uint24 _distributionCurrency) external {
        JBFundAccessConstraints[] memory _fundAccessConstraints = new JBFundAccessConstraints[](1);
        JBCurrencyAmount[] memory _distributionLimits = new JBCurrencyAmount[](2);
        JBCurrencyAmount[] memory _overflowAllowances = new JBCurrencyAmount[](1);

        _distributionLimits[0] = JBCurrencyAmount({
            value: 1,
            currency: _distributionCurrency
        });

        _distributionLimits[1] = JBCurrencyAmount({
            value: 1,
            currency: _distributionCurrency == 0 ? 0 : _distributionCurrency - 1
        });

        _overflowAllowances[0] = JBCurrencyAmount({
            value: 1,
            currency: 1
        });

        _fundAccessConstraints[0] = 
            JBFundAccessConstraints({
                terminal: _terminal3_2,
                token: jbLibraries().ETHToken(),
                distributionLimits: _distributionLimits,
                overflowAllowances: _overflowAllowances
            });

        JBFundingCycleConfiguration[] memory _cycleConfig = new JBFundingCycleConfiguration[](1);

        _cycleConfig[0].mustStartAtOrAfter = 0;
        _cycleConfig[0].data = _data;
        _cycleConfig[0].metadata = _metadata;
        _cycleConfig[0].groupedSplits = _groupedSplits;
        _cycleConfig[0].fundAccessConstraints = _fundAccessConstraints;

        _projectOwner = multisig();

        vm.prank(_projectOwner);

        vm.expectRevert(abi.encodeWithSignature("INVALID_DISTRIBUTION_LIMIT_CURRENCY_ORDERING()"));
        
        _controller.launchProjectFor({
            owner: _projectOwner,
            projectMetadata: _projectMetadata,
            configurations: _cycleConfig,
            terminals: _terminals,
            memo: ""
        });
    }

    function testFuzzedConfigureAccess(uint232 _distributionLimit, uint232 _allowanceLimit, uint256 _distributionCurrency, uint256 ALLOWCURRENCY) external {
        _distributionCurrency = bound(uint256(_distributionCurrency), uint256(0), type(uint24).max - 1);
        ALLOWCURRENCY = bound(uint256(ALLOWCURRENCY), uint256(0), type(uint24).max - 1);
        
        JBFundAccessConstraints[] memory _fundAccessConstraints = new JBFundAccessConstraints[](1);
        JBCurrencyAmount[] memory _distributionLimits = new JBCurrencyAmount[](2);
        JBCurrencyAmount[] memory _overflowAllowances = new JBCurrencyAmount[](2);

        _distributionLimits[0] = JBCurrencyAmount({
            value: _distributionLimit,
            currency: _distributionCurrency
        });

        _distributionLimits[1] = JBCurrencyAmount({
            value: _distributionLimit,
            currency: _distributionCurrency + 1
        });
        _overflowAllowances[0] = JBCurrencyAmount({
            value: _allowanceLimit,
            currency: ALLOWCURRENCY
        });
        _overflowAllowances[1] = JBCurrencyAmount({
            value: _allowanceLimit,
            currency: ALLOWCURRENCY + 1
        });
        _fundAccessConstraints[0] = 
            JBFundAccessConstraints({
                terminal: _terminal3_2,
                token: jbLibraries().ETHToken(),
                distributionLimits: _distributionLimits,
                overflowAllowances: _overflowAllowances
            });
        JBFundingCycleConfiguration[] memory _cycleConfig = new JBFundingCycleConfiguration[](1);
        _cycleConfig[0].mustStartAtOrAfter = 0;
        _cycleConfig[0].data = _data;
        _cycleConfig[0].metadata = _metadata;
        _cycleConfig[0].groupedSplits = _groupedSplits;
        _cycleConfig[0].fundAccessConstraints = _fundAccessConstraints;

        _controller.launchProjectFor({
            owner: _projectOwner,
            projectMetadata: _projectMetadata,
            configurations: _cycleConfig,
            terminals: _terminals,
            memo: ""
        });
    }

    function testFailMultipleDistroLimitCurrenciesOverLimit() external {
        uint256 _ethPayAmount = 1.5 ether;
        uint256 _ethDistributionLimit = 1 ether;
        uint256 _ethPricePerUsd = 0.0005 * 10**18; // 1/2000
        // More than the treasury will have available.
        uint256 _usdDistributionLimit = PRBMath.mulDiv(1 ether, 10**18, _ethPricePerUsd);

        // Package up fund access constraints
        JBFundAccessConstraints[] memory _fundAccessConstraints = new JBFundAccessConstraints[](1);
        JBCurrencyAmount[] memory _distributionLimits = new JBCurrencyAmount[](2);
        JBCurrencyAmount[] memory _overflowAllowances = new JBCurrencyAmount[](1);
        
        _distributionLimits[0] = JBCurrencyAmount({
            value: _ethDistributionLimit,
            currency: _ethCurrency
        });
        _distributionLimits[1] = JBCurrencyAmount({
            value: _usdDistributionLimit,
            currency: _usdCurrency
        });
        _overflowAllowances[0] = JBCurrencyAmount({
            value: 1,
            currency: 1
        });
        _fundAccessConstraints[0] = 
            JBFundAccessConstraints({
                terminal: _terminal3_2,
                token: jbLibraries().ETHToken(),
                distributionLimits: _distributionLimits,
                overflowAllowances: _overflowAllowances
            });

        // Package up cycle config.
        JBFundingCycleConfiguration[] memory _cycleConfig = new JBFundingCycleConfiguration[](1);
        _cycleConfig[0].mustStartAtOrAfter = 0;
        _cycleConfig[0].data = _data;
        _cycleConfig[0].metadata = _metadata;
        _cycleConfig[0].groupedSplits = _groupedSplits;
        _cycleConfig[0].fundAccessConstraints = _fundAccessConstraints;

        // dummy
        _controller.launchProjectFor({
            owner: address(420), //random
            projectMetadata: _projectMetadata,
            configurations: _cycleConfig,
            terminals: _terminals,
            memo: ""
        });

        uint256 _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectMetadata: _projectMetadata,
            configurations: _cycleConfig,
            terminals: _terminals,
            memo: ""
        });

        _terminal3_2.pay{value: _ethPayAmount}({
            projectId: _projectId,
            amount: _ethPayAmount,
            token: address(0), // unused
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            preferClaimedTokens: false,
            memo: "Take my money!",
            metadata: new bytes(0)
        });

        // Make sure beneficiary has a balance of JBTokens
        uint256 _userTokenBalance = PRBMathUD60x18.mul(_ethPayAmount, _data.weight);
        assertEq(_tokenStore.balanceOf(_beneficiary, _projectId), _userTokenBalance);
        uint256 initTerminalBalance = address(_terminal3_2).balance;

        // First dist should be fine based on price
        _terminal3_2.distributePayoutsOf({
            projectId: _projectId,
            amount: 1800000000,
            currency: _usdCurrency,
            token: address(0), // unused 
            minReturnedTokens: 0,
            metadata: "lfg"
        });

        uint256 _distributedAmount = PRBMath.mulDiv(
            1800000000,
            10**18, // Use _MAX_FIXED_POINT_FIDELITY to keep as much of the `_amount.value`'s fidelity as possible when converting.
            _prices.priceFor({
                projectId: 1, 
                currency: _usdCurrency, 
                base: _ethCurrency, 
                decimals: 18
            })
        );

        // Make sure the remaining balance is correct.
        assertEq(
            address(_terminal3_2).balance,
            initTerminalBalance - PRBMath.mulDiv(_distributedAmount, jbLibraries().MAX_FEE(), jbLibraries().MAX_FEE() + _terminal3_2.fee())
        );

        // Next dist should be fine based on price
        _terminal3_2.distributePayoutsOf({
            projectId: _projectId,
            amount: 1700000000,
            currency: _usdCurrency,
            token: address(0), // unused 
            minReturnedTokens: 0,
            metadata: "lfg"
        });
    }

    function testMultipleDistroLimitCurrencies() external {
        uint256 _ethPayAmount = 3 ether;
        vm.deal(_beneficiary, _ethPayAmount);
        vm.prank(_beneficiary);

        JBFundAccessConstraints[] memory _fundAccessConstraints = new JBFundAccessConstraints[](1);
        JBCurrencyAmount[] memory _distributionLimits = new JBCurrencyAmount[](2);
        _distributionLimits[0] = JBCurrencyAmount({
            value: 1 ether,
            currency: _ethCurrency
        });
        _distributionLimits[1] = JBCurrencyAmount({
            value: 2000 * 10**18,
            currency: _usdCurrency
        });
        _fundAccessConstraints[0] = 
            JBFundAccessConstraints({
                terminal: _terminal3_2,
                token: jbLibraries().ETHToken(),
                distributionLimits: _distributionLimits,
                overflowAllowances: new JBCurrencyAmount[](0)
            });

        JBFundingCycleConfiguration[] memory _cycleConfig = new JBFundingCycleConfiguration[](1);

        _cycleConfig[0].mustStartAtOrAfter = 0;
        _cycleConfig[0].data = _data;
        _cycleConfig[0].metadata = _metadata;
        _cycleConfig[0].groupedSplits = _groupedSplits;
        _cycleConfig[0].fundAccessConstraints = _fundAccessConstraints;

        uint256 _projectId = _controller.launchProjectFor(
            _projectOwner,
            _projectMetadata,
            _cycleConfig,
            _terminals,
            ""
        );

        _terminal3_2.pay{value: _ethPayAmount}({
            projectId: _projectId,
            amount: _ethPayAmount,
            token: address(0), // unused
            beneficiary: _beneficiary,
            minReturnedTokens: 0,
            preferClaimedTokens: false,
            memo: "Take my money!",
            metadata: new bytes(0)
        });

        uint256 _price = 0.0005 * 10**18; // 1/2000
        vm.startPrank(_projectOwner);
        MockPriceFeed _priceFeedEthUsd = new MockPriceFeed(_price, 18);
        vm.label(address(_priceFeedEthUsd), "MockPrice Feed MyToken-ETH");

        _prices.addFeedFor({
            projectId: _projectId,
            currency: _ethCurrency,
            base: _usdCurrency,
            priceFeed: _priceFeedEthUsd
        });

        // Make sure the beneficiary has a balance of JBTokens
        uint256 _userTokenBalance = PRBMathUD60x18.mul(_ethPayAmount, _data.weight);
        assertEq(_tokenStore.balanceOf(_beneficiary, _projectId), _userTokenBalance);

        uint256 initTerminalBalance = address(_terminal3_2).balance;
        uint256 ownerBalanceBeforeFirst = _projectOwner.balance;

        _terminal3_2.distributePayoutsOf({
            projectId: _projectId,
            amount: 3000000000,
            currency: _usdCurrency,
            token: address(0), // unused
            minReturnedTokens: 0,
            metadata: "lfg"
        });

        uint256 _distributedAmount = PRBMath.mulDiv(
            3000000000,
            10**18, // Use _MAX_FIXED_POINT_FIDELITY to keep as much of the `_amount.value`'s fidelity as possible when converting.
            _prices.priceFor({
                projectId: 1, 
                currency: _usdCurrency, 
                base: _ethCurrency, 
                decimals: 18
            })
        );

        assertEq(
            _projectOwner.balance,
            ownerBalanceBeforeFirst + PRBMath.mulDiv(_distributedAmount, jbLibraries().MAX_FEE(), jbLibraries().MAX_FEE() + _terminal3_2.fee())
        );

        // Funds leaving the ecosystem -> fee taken
        assertEq(
            address(_terminal3_2).balance,
            initTerminalBalance - PRBMath.mulDiv(_distributedAmount, jbLibraries().MAX_FEE(), jbLibraries().MAX_FEE() + _terminal3_2.fee())
        );

        uint256 _balanceBeforeEthDist = address(_terminal3_2).balance;
        uint256 _ownerBalanceBeforeEthDist = _projectOwner.balance;

        _terminal3_2.distributePayoutsOf({
            projectId: _projectId,
            amount: 1 ether,
            currency: _ethCurrency,
            token: address(0), // unused
            minReturnedTokens: 0,
            metadata: "lfg"
        });

        // Funds leaving the ecosystem -> fee taken
        assertEq(
            _projectOwner.balance,
            _ownerBalanceBeforeEthDist + PRBMath.mulDiv(1 ether, jbLibraries().MAX_FEE(), jbLibraries().MAX_FEE() + _terminal3_2.fee())
        );

        assertEq(
            address(_terminal3_2).balance,
            _balanceBeforeEthDist - PRBMath.mulDiv(1 ether, jbLibraries().MAX_FEE(), jbLibraries().MAX_FEE() + _terminal3_2.fee())
        );
    }
}
