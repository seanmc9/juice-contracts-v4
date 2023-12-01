// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {JBSplitGroup} from "./../structs/JBSplitGroup.sol";
import {JBSplit} from "./../structs/JBSplit.sol";
import {IJBDirectory} from "./IJBDirectory.sol";
import {IJBProjects} from "./IJBProjects.sol";

interface IJBSplits {
    event SetSplit(
        uint256 indexed projectId,
        uint256 indexed domainId,
        uint256 indexed group,
        JBSplit split,
        address caller
    );

    function projects() external view returns (IJBProjects);

    function directory() external view returns (IJBDirectory);

    function splitsOf(uint256 projectId, uint256 domainId, uint256 group)
        external
        view
        returns (JBSplit[] memory);

    function setSplitGroupsFor(
        uint256 projectId,
        uint256 domainId,
        JBSplitGroup[] memory splitGroups
    ) external;
}