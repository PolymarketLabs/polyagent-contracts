// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.30;

struct Fund {
    address vault;
    address baseAsset;
    address manager; // 基金经理，当前版本只记录信息，不参与其他验证与交互
    address admin;
    address operator;
    address executor;
    uint256 createdAt;
}
