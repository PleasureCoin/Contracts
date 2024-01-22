// contracts/NSFWStaking.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";


contract NSFWFreezableUpgradable is Initializable, ContextUpgradeable, AccessControlUpgradeable {
    uint8 constant internal DEPOSIT_FREEZE   = 0xC0;
    uint8 constant internal REWARD_FREEZE    = 0x30;
    uint8 constant internal CLAIM_FREEZE     = 0x0C;
    uint8 constant internal WITHDRAW_FREEZE  = 0x03;

    uint8 public currentFreeze;

    function __NSFWFreezableUpgradable_init() internal initializer {
        __Context_init_unchained();
        __NSFWFreezableUpgradable_init_unchained();
    }

    function __NSFWFreezableUpgradable_init_unchained() internal initializer {
        currentFreeze = 0;
    }

    function setDepositFreeze(bool status) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (((currentFreeze & DEPOSIT_FREEZE) != 0) != status)
            currentFreeze = currentFreeze ^ DEPOSIT_FREEZE;
    }

    function setRewardFreeze(bool status) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (((currentFreeze & REWARD_FREEZE) != 0) != status)
            currentFreeze = currentFreeze ^ REWARD_FREEZE;
    }

    function setClaimFreeze(bool status) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (((currentFreeze & CLAIM_FREEZE) != 0) != status)
            currentFreeze = currentFreeze ^ CLAIM_FREEZE;
    }

    function setWithdrawFreeze(bool status) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (((currentFreeze & WITHDRAW_FREEZE) != 0) != status)
            currentFreeze = currentFreeze ^ WITHDRAW_FREEZE;
    }

    modifier whenFreezeIs(uint8 freezeMask, bool status) {
        require(((currentFreeze & freezeMask) != 0) == status, "This operation is currently unavailable");
        _;
    }

}