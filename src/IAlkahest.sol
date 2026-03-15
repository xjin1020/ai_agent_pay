// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal EAS Attestation struct for Alkahest compatibility
// Full spec: https://github.com/ethereum-attestation-service/eas-contracts

struct Attestation {
    bytes32 uid;
    bytes32 schema;
    uint64 time;
    uint64 expirationTime;
    uint64 revocationTime;
    bytes32 refUID;
    address attester;
    address recipient;
    bool revocable;
    bytes data;
}
