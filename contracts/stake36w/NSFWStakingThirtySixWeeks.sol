// contracts/NSFWStakingTwelveWeeks.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "./NSFWFreezableUpgradable.sol";

contract NSFWStakingThirtySixWeeks is OwnableUpgradeable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, NSFWFreezableUpgradable {
    using SafeERC20Upgradeable for ERC20Upgradeable;

    struct UnlockData {
        uint256 effectivePeriod;
        int256 amount;
    }

    struct UserData {
        uint256 lastUpdate; //period number
        uint256 lastDepositPeriod;
        int256 totalUnlocked;
        int256 totalStaked;
        int256 totalRewards;
        mapping(uint256 => int256) history;
        UnlockData unlock;
    }

    uint256 constant private MIN_DEPOSIT = 100000;
    uint256 constant public  PERIOD_COUNT = 36;

    ERC20Upgradeable private _token;
    bool public initialized;
    uint256 public maxHistorySize;
    bool public emergencyUnlockStatus;

    uint256 public currentPeriod;
    int256 public totalStaked;
    mapping(uint256 => int256) public globalHistory;
    mapping(uint256 => int256) public sharePrice;
    mapping(address => UserData) public userDatas;

    uint256 constant public ONE_WEEK = 604800;
    uint256 constant public UNIX_FIRST_MONDAY = 342000;

    uint256 public contractFirstMonday;

    int256 constant private _PRECISION_FACTOR = 1e36;

    function getStakedBalance(address account) external view whenInitialized returns(int256) {
        int256 staked = userDatas[account].totalStaked;
        for (uint256 i = userDatas[account].lastUpdate; i <= currentPeriod; i++) {
            staked += userDatas[account].history[i];
        }

        return staked;
    }

    function getHistory(address account, uint256 period) external view returns(int256) {
        return userDatas[account].history[period];
    }
    function getUserReward(address account) external view whenInitialized returns(int256) {
        int256 staked = userDatas[account].totalStaked;
        int256 rewards = userDatas[account].totalRewards;
        for (uint256 i = userDatas[account].lastUpdate; i < currentPeriod; i++) {
            staked += userDatas[account].history[i];
            rewards += (staked * sharePrice[i]) / _PRECISION_FACTOR;
        }

        return rewards;
    }

    function getUnlockedBalance(address account) external view whenInitialized returns(int256) {
        int256 unlocked = userDatas[account].totalUnlocked;
        for (uint256 i = userDatas[account].lastUpdate; i <= currentPeriod; i++) {
            if (userDatas[account].history[i] < 0)
                unlocked -= userDatas[account].history[i];
        }

        return unlocked;
    }
    
    function getEntranceBalance(address account) external view whenInitialized returns(int256) {
        if (userDatas[account].history[currentPeriod + 1] > 0)
            return userDatas[account].history[currentPeriod + 1];
        else
            return 0;
    }

    function getTotalBalance(address account) external view whenInitialized returns(int256) {
        int256 total = userDatas[account].totalStaked;
        for (uint256 i = userDatas[account].lastUpdate; i <= currentPeriod; i++) {
            total += userDatas[account].history[i];
        }

        if (userDatas[account].history[currentPeriod + 1] > 0)
            return total + userDatas[account].history[currentPeriod + 1];
        else
            return total;
    }

    function getUnlockRequested(address account) whenInitialized external view returns(bool) {
        return userDatas[account].unlock.amount != 0;
    }

    function getUnlockedDate(address account) external view returns(uint256) {
        require (userDatas[account].unlock.amount != 0, "No unlock Requested");
        return contractFirstMonday + userDatas[account].unlock.effectivePeriod * ONE_WEEK;
    }

    function getUnlockAmount(address account) whenInitialized external view returns(int256) {
        return userDatas[account].unlock.amount;
    }

    function getMinimalUnlockDate(address account) external view returns(uint256) {
        UserData storage userData = userDatas[account];
        uint256 unlockPeriod = currentPeriod >= userData.lastDepositPeriod
            ? currentPeriod + (PERIOD_COUNT - ((currentPeriod - userData.lastDepositPeriod) % PERIOD_COUNT))
            : userData.lastDepositPeriod + PERIOD_COUNT;
        if (unlockPeriod - currentPeriod == 1)
            unlockPeriod += PERIOD_COUNT;
        return contractFirstMonday + unlockPeriod * ONE_WEEK;
    }


    function sendReward(uint256 amount) payable external nonReentrant whenInitialized onlyRole(DEFAULT_ADMIN_ROLE) {
        require(contractFirstMonday + (currentPeriod + 1) * ONE_WEEK <= block.timestamp, "You can't send any rewards until next monday");
        require((totalStaked > 0 && amount > 0) || (totalStaked == 0 && amount == 0), "Token must be staked to send more than 0 BNB");
        require(_token.allowance(msg.sender, address(this)) >= uint256(amount), "ERC20: transfer amount exceeds allowance.");

        _token.safeTransferFrom(msg.sender, address(this), uint256(amount));
        if (totalStaked > 0)
            sharePrice[currentPeriod] = (int256(amount) * _PRECISION_FACTOR) / totalStaked; //Warning, critical failure if multiple call during one period
        currentPeriod++;
        totalStaked += globalHistory[currentPeriod];
    }

    function requestUnlock() external hardUpdate nonReentrant whenInitialized {
        if (userDatas[msg.sender].unlock.amount > 0)
            return;
        UserData storage userData = userDatas[msg.sender];
        userData.unlock.amount = userData.totalStaked + userData.history[currentPeriod + 1];
        userData.unlock.effectivePeriod = currentPeriod >= userData.lastDepositPeriod
            ? currentPeriod + (PERIOD_COUNT - ((currentPeriod - userData.lastDepositPeriod) % PERIOD_COUNT))
            : userData.lastDepositPeriod + PERIOD_COUNT;
        if (userData.unlock.effectivePeriod - currentPeriod == 1)
            userData.unlock.effectivePeriod += PERIOD_COUNT;
        userData.history[userData.unlock.effectivePeriod] -= userData.unlock.amount;
        globalHistory[userData.unlock.effectivePeriod] -= userData.unlock.amount;
    }

    function update() public nonReentrant whenInitialized returns (bool) {
        UserData storage userData = userDatas[msg.sender];
        uint256 maxPeriod = currentPeriod - userData.lastUpdate > maxHistorySize 
            ? userData.lastUpdate + maxHistorySize
            : currentPeriod;

        for (uint256 i = userData.lastUpdate; i <= maxPeriod; i++) {
            if (userData.history[i] < 0) {
                userData.totalUnlocked -= userData.history[i];
                delete userData.unlock.effectivePeriod;
                delete userData.unlock.amount;
            }
            userData.totalStaked += userData.history[i];
            userData.totalRewards += (userData.totalStaked * sharePrice[i]) / _PRECISION_FACTOR;
            delete userData.history[i];
        }
        userData.lastUpdate = maxPeriod;

        return maxPeriod == currentPeriod;
    }

    function update(address account) public nonReentrant whenInitialized returns (bool) {
        UserData storage userData = userDatas[account];
        uint256 maxPeriod = currentPeriod - userData.lastUpdate > maxHistorySize 
            ? userData.lastUpdate + maxHistorySize
            : currentPeriod;

        for (uint256 i = userData.lastUpdate; i <= maxPeriod; i++) {
            if (userData.history[i] < 0) {
                userData.totalUnlocked -= userData.history[i];
                delete userData.unlock.effectivePeriod;
                delete userData.unlock.amount;
            }
            userData.totalStaked += userData.history[i];
            userData.totalRewards += (userData.totalStaked * sharePrice[i]) / _PRECISION_FACTOR;
            delete userData.history[i];
        }
        userData.lastUpdate = maxPeriod;

        return maxPeriod == currentPeriod;
    }


    // function getAllNsfw() external onlyRole(DEFAULT_ADMIN_ROLE) {
    //     uint256 amount = _token.balanceOf(address(this));
    //     _token.safeTransfer(address(msg.sender), amount);
    // }
//
    // function getAllMatics() external onlyRole(DEFAULT_ADMIN_ROLE) {
    //     uint256 amount = address(this).balance;
    //     payable(msg.sender).transfer(amount);
    // }

    modifier hardUpdate() {
        require(update(), "Perform manual");
        _;
    }

    function batchInsert(address[] memory accounts, int256[] memory entranceBalances, int256[] memory stakedBalances, int256[] memory
            unlockedBalances,bool[] memory unlocksRequested, uint256[] memory unlocksEffectivePeriods, uint256[] memory lastDeposits,
            int256[] memory unlocksAmounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < accounts.length; i++) {
            UserData storage userData = userDatas[accounts[i]];
            userData.lastUpdate = currentPeriod;
            userData.lastDepositPeriod = lastDeposits[i];
            
            if (unlockedBalances[i] != 0)
                userData.totalUnlocked = unlockedBalances[i];

            if (userData.totalStaked != 0)
                totalStaked -= userData.totalStaked;

            userData.totalStaked = stakedBalances[i];
            totalStaked += stakedBalances[i];

            if (entranceBalances[i] != 0) {
                if(userData.history[currentPeriod + 1] != 0)
                    globalHistory[currentPeriod + 1] -= userData.history[currentPeriod + 1];
                userData.history[currentPeriod + 1] = entranceBalances[i];
                globalHistory[currentPeriod + 1] += entranceBalances[i];
            }
            
            if (unlocksRequested[i]) {
                if (userData.unlock.amount != 0)
                    globalHistory[userData.unlock.effectivePeriod] += userData.unlock.amount;
                if (unlocksEffectivePeriods[i] > currentPeriod) {
                    userData.unlock.amount = unlocksAmounts[i];
                    userData.unlock.effectivePeriod = unlocksEffectivePeriods[i];
                    globalHistory[unlocksEffectivePeriods[i]] -= userData.unlock.amount;
                    userData.history[unlocksEffectivePeriods[i]] -= userData.unlock.amount;
                } else {
                    userData.totalUnlocked = unlocksAmounts[i];
                }
            }
        }
    }

    function batchSetRewards(address[] memory accounts, int256[] memory totalRewards) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint8 i = 0; i < accounts.length; i++) {
            require(update(accounts[i]), "Could not update one of those accounts");
            UserData storage userData = userDatas[accounts[i]];
            userData.totalRewards = totalRewards[i];
        }
    }

    function resetGlobals() external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint i = 0; i <= (currentPeriod + PERIOD_COUNT) * 2; i++) {
            delete globalHistory[i];
        }
        delete totalStaked;
    }

    // We need this?
    // function resetUsers(address [] memory accounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
    //     for (uint i = 0; i < accounts.length; i++) {
    //         UserData storage userData = userDatas[accounts[i]];
    //         delete userData.lastUpdate;
    //         delete userData.lastDepositPeriod;
    //         delete userData.totalUnlocked;
    //         delete userData.totalStaked;
    //         delete userData.totalRewards;
    //         delete userData.unlock.effectivePeriod;
    //         delete userData.unlock.amount;
    //         delete userData.unlock;
    //         for (uint j = currentPeriod; j <= (currentPeriod + PERIOD_COUNT) * 2; j++) {
    //             if (userData.history[j] != 0)
    //                 delete userData.history[j];
    //         }
    //     }
    // }

    //Administration Related


    //Initialization related

    function initialize() public initializer {
        __Ownable_init_unchained();
        __AccessControl_init();
        __ReentrancyGuard_init();
    }

    function startContract(address tokenAddress) whenNotInitialized onlyOwner external {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _token = ERC20Upgradeable(tokenAddress);
        initialized = true;
        maxHistorySize = 260;
        currentPeriod = 0;
        contractFirstMonday = block.timestamp - ((block.timestamp - UNIX_FIRST_MONDAY) % ONE_WEEK);
    }

    modifier whenNotInitialized {
        require(!initialized, "Initialized");
        _;
    }

    modifier whenInitialized {
        require(initialized, "Not initialized");
        _;
    }
}