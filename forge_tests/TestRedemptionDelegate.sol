// SPDX-License-Identifier: MIT
pragma solidity >=0.8.6;

import /* {*} from */ "./helpers/TestBaseWorkflow.sol";

contract TestDelegates_Local is TestBaseWorkflow {
    uint256 private constant _WEIGHT = 1000 * 10 ** 18;
    address private constant _DATA_SOURCE = address(bytes20(keccak256("datasource")));

    IJBController3_1 private _controller;
    IJBPaymentTerminal private _terminal;
    IJBTokenStore private _tokenStore;
    address private _projectOwner;
    address private _beneficiary;
    address private _payer;

    uint256 _projectId;

    function setUp() public override {
        super.setUp();

        vm.label(_DATA_SOURCE, "Data Source");

        _controller = jbController();
        _projectOwner = multisig();
        _beneficiary = beneficiary();
        _terminal = jbPayoutRedemptionTerminal();
        _tokenStore = jbTokenStore();

        JBFundingCycleData memory _data = JBFundingCycleData({
            duration: 0,
            weight: _WEIGHT,
            discountRate: 0,
            ballot: IJBFundingCycleBallot(address(0))
        });

        JBFundingCycleMetadata memory _metadata = JBFundingCycleMetadata({
            global: JBGlobalFundingCycleMetadata({
                allowSetTerminals: false,
                allowSetController: false,
                pauseTransfers: false
            }),
            reservedRate: 0,
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE / 2,
            baseCurrency: uint32(uint160(JBTokens.ETH)),
            pausePay: false,
            allowMinting: true,
            allowTerminalMigration: false,
            allowControllerMigration: false,
            holdFees: false,
            useTotalOverflowForRedemptions: true,
            useDataSourceForPay: false,
            useDataSourceForRedeem: true,
            dataSource: _DATA_SOURCE,
            metadata: 0
        });

        // Package up cycle config.
        JBFundingCycleConfig[] memory _cycleConfig = new JBFundingCycleConfig[](1);
        _cycleConfig[0].mustStartAtOrAfter = 0;
        _cycleConfig[0].data = _data;
        _cycleConfig[0].metadata = _metadata;
        _cycleConfig[0].groupedSplits = new JBGroupedSplits[](0);
        _cycleConfig[0].fundAccessConstraints = new JBFundAccessConstraints[](0);

        JBTerminalConfig[] memory _terminalConfigurations = new JBTerminalConfig[](1);
        JBAccountingContextConfig[] memory _accountingContexts = new JBAccountingContextConfig[](1);
        _accountingContexts[0] =
            JBAccountingContextConfig({token: JBTokens.ETH, standard: JBTokenStandards.NATIVE});
        _terminalConfigurations[0] =
            JBTerminalConfig({terminal: _terminal, accountingContextConfigs: _accountingContexts});

        // First project for fee collection
        _controller.launchProjectFor({
            owner: _projectOwner,
            projectMetadata: JBProjectMetadata({content: "myIPFSHash", domain: 0}),
            fundingCycleConfigurations: _cycleConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        _projectId = _controller.launchProjectFor({
            owner: _projectOwner,
            projectMetadata: JBProjectMetadata({content: "myIPFSHash", domain: 1}),
            fundingCycleConfigurations: _cycleConfig,
            terminalConfigurations: _terminalConfigurations,
            memo: ""
        });

        // Issue the project's tokens.
        vm.prank(_projectOwner);
        IJBToken _token = _tokenStore.issueFor(_projectId, "TestName", "TestSymbol");

        // Make sure the project's new JBToken is set.
        assertEq(address(_tokenStore.tokenOf(_projectId)), address(_token));
    }

    function testRedemptionDelegate() public {
        // Reference and bound pay amount
       uint256 _ethPayAmount = 10 ether;

        // Delegate address
        address _redDelegate = makeAddr("SOFA");
        vm.label(_redDelegate, "Redemption Delegate");

        // Keep a reference to the current funding cycle.
        (JBFundingCycle memory _fundingCycle,) = _controller.currentFundingCycleOf(_projectId);

        // Reference tokens received from pay
        uint256 _redeemableReceived = 1 ether;

        // Reference allocations
        JBRedemptionDelegateAllocation3_1_1[] memory _allocations = new JBRedemptionDelegateAllocation3_1_1[](1);

        _allocations[0] = JBRedemptionDelegateAllocation3_1_1({
            delegate: IJBRedemptionDelegate3_1_1(_redDelegate),
            amount: _redeemableReceived,
            metadata: ""
        });

        // Redemption Data
        JBDidRedeemData3_1_1 memory _redeemData = JBDidRedeemData3_1_1({
            holder: address(this),
            projectId: _projectId,
            currentFundingCycleConfiguration: _fundingCycle.configuration,
            projectTokenCount: 1 ether,
            reclaimedAmount: JBTokenAmount(
                    JBTokens.ETH,
                    _ethPayAmount,
                    _terminal.accountingContextForTokenOf(_projectId, JBTokens.ETH).decimals,
                    _terminal.accountingContextForTokenOf(_projectId, JBTokens.ETH).currency
                    ),
            forwardedAmount: JBTokenAmount(
                    address(jbTokenStore().tokenOf(_projectId)),
                    _redeemableReceived,
                    _terminal.accountingContextForTokenOf(_projectId, JBTokens.ETH).decimals,
                    _terminal.accountingContextForTokenOf(_projectId, JBTokens.ETH).currency
                    ),
            redemptionRate: JBConstants.MAX_REDEMPTION_RATE,
            beneficiary: payable(address(this)),
            dataSourceMetadata: "",
            redeemerMetadata: ""
        });

        vm.deal(address(this), 10 ether);
        _terminal.pay{value: _ethPayAmount}({
            projectId: _projectId,
            amount: 10 ether,
            token: JBTokens.ETH,
            beneficiary: address(this),
            minReturnedTokens: 0,
            memo: "Forge Test",
            metadata: ""
        });

        // Mock the delegate
        vm.mockCall(
            _redDelegate,
            abi.encodeWithSelector(IJBRedemptionDelegate3_1_1.didRedeem.selector),
            abi.encode(_redeemData)
        );

        // Assert that the delegate gets called with the expected value
        vm.expectCall(
            _redDelegate,
            _redeemableReceived,
            abi.encodeWithSelector(IJBRedemptionDelegate3_1_1.didRedeem.selector, _redeemData)
        );

        vm.prank(_projectOwner);
        // Mint tokens to beneficiary.
        _controller.mintTokensOf({
            projectId: _projectId,
            tokenCount: 1 ether,
            beneficiary: address(this),
            memo: "Mint memo",
            useReservedRate: true
        });

        vm.mockCall(
            _DATA_SOURCE,
            abi.encodeWithSelector(IJBFundingCycleDataSource3_1_1.redeemParams.selector),
            abi.encode(_ethPayAmount, _allocations)
            );
        
        _terminal.redeemTokensOf({
            holder: address(this),
            projectId: _projectId,
            count: PRBMathUD60x18.mul(_ethPayAmount, _WEIGHT),
            token: JBTokens.ETH,
            minReclaimed: 0,
            beneficiary: payable(address(this)),
            metadata: new bytes(0)
        });
    }
}