// contracts/NSFWStakingTwelveWeeks.sol
// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

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
    uint256 constant private MAX_DEPOSIT = 1000000000;
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

    function deposit(int256 amount) external hardUpdate nonReentrant whenInitialized whenFreezeIs(DEPOSIT_FREEZE, false) {
        require(amount >= 0, "Token amount can't be less than 0");
        require(uint256(amount) >= MIN_DEPOSIT * 10 ** _token.decimals(), "Token amount should be superior to the minimal deposit");
        require(uint256(amount) <= MAX_DEPOSIT * 10 ** _token.decimals(), "Token amount should be inferior to the maximal deposit");
        require(_token.allowance(msg.sender, address(this)) >= uint256(amount), "ERC20: transfer amount exceeds allowance.");
        _token.safeTransferFrom(msg.sender, address(this), uint256(amount));

        UserData storage userData = userDatas[msg.sender];
        userData.history[currentPeriod + 1] += int256(amount);
        globalHistory[currentPeriod + 1] += int256(amount);
        userData.lastDepositPeriod = currentPeriod + 1;

        //handling previous unlock requests
        if (userData.unlock.amount != 0) {
            userData.history[userData.unlock.effectivePeriod] += userData.unlock.amount;
            globalHistory[userData.unlock.effectivePeriod] += userData.unlock.amount;
            delete userData.unlock.amount;
            delete userData.unlock.effectivePeriod;
        }
    }

    function withdraw() external hardUpdate nonReentrant whenInitialized whenFreezeIs(WITHDRAW_FREEZE, false) {
        uint256 totalToWithdraw = uint256(userDatas[msg.sender].totalUnlocked);
        delete userDatas[msg.sender].totalUnlocked;

        if (emergencyUnlockStatus) {
            totalToWithdraw += uint256(userDatas[msg.sender].totalStaked);
            totalStaked -= userDatas[msg.sender].totalStaked;
            delete userDatas[msg.sender].totalStaked;

            if (userDatas[msg.sender].history[currentPeriod + 1] > 0) {
                totalToWithdraw += uint256(userDatas[msg.sender].history[currentPeriod + 1]);
                globalHistory[currentPeriod + 1] -= userDatas[msg.sender].history[currentPeriod + 1];
                delete userDatas[msg.sender].history[currentPeriod + 1];
            }

            if (userDatas[msg.sender].unlock.amount > 0) {
                UnlockData memory unlock = userDatas[msg.sender].unlock;
                userDatas[msg.sender].history[unlock.effectivePeriod] += unlock.amount;
                globalHistory[unlock.effectivePeriod] += unlock.amount;
                delete userDatas[msg.sender].unlock.amount;
                delete userDatas[msg.sender].unlock.effectivePeriod;
            }
        }
        require(totalToWithdraw > 0, "You have no token to withdraw");
        _token.safeTransfer(msg.sender, totalToWithdraw);
    }

    function claimReward() external hardUpdate nonReentrant whenInitialized whenFreezeIs(CLAIM_FREEZE, false) {
        require(userDatas[msg.sender].totalRewards > 0, "You have no rewards to claim");
        _token.safeTransfer(address(msg.sender), uint256(userDatas[msg.sender].totalRewards));
        delete userDatas[msg.sender].totalRewards;
    }

    function sendReward(uint256 amount) payable external nonReentrant whenInitialized onlyRole(DEFAULT_ADMIN_ROLE) whenFreezeIs(REWARD_FREEZE, false) {
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

    function emergencyUnlock(bool value) external onlyRole(DEFAULT_ADMIN_ROLE) whenInitialized {
        emergencyUnlockStatus = value;
    }

    //Dev methods

    function forceVariation(address account, uint256 effectivePeriod, int256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        userDatas[account].history[effectivePeriod] += amount;
        globalHistory[effectivePeriod] += amount;
    }

    function forceCurrentPeriod(uint256 period) external onlyRole(DEFAULT_ADMIN_ROLE) {
        currentPeriod = period;
    }

    function updateMaxHistorySize(uint256 newMaxHistorySize) external onlyRole(DEFAULT_ADMIN_ROLE) {
        maxHistorySize = newMaxHistorySize;
    }

    function setContractFirstMonday(uint256 newContractFirstMonday) external onlyRole(DEFAULT_ADMIN_ROLE) {
        contractFirstMonday = newContractFirstMonday;
    }

    function getAllNsfw() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 amount = _token.balanceOf(address(this));
        _token.safeTransfer(address(msg.sender), amount);
    }

    function getAllMatics() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 amount = address(this).balance;
        payable(msg.sender).transfer(amount);
    }

    modifier hardUpdate() {
        require(update(), "You must perform a manual update to execute this method");
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

    function resetUsers(address [] memory accounts) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint i = 0; i < accounts.length; i++) {
            UserData storage userData = userDatas[accounts[i]];
            delete userData.lastUpdate;
            delete userData.lastDepositPeriod;
            delete userData.totalUnlocked;
            delete userData.totalStaked;
            delete userData.totalRewards;
            delete userData.unlock.effectivePeriod;
            delete userData.unlock.amount;
            delete userData.unlock;
            for (uint j = currentPeriod; j <= (currentPeriod + PERIOD_COUNT) * 2; j++) {
                if (userData.history[j] != 0)
                    delete userData.history[j];
            }
        }
    }

    //Administration Related

    function isAdmin(address account) external view returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, account);
    }

    function setTokenAddress(address tokenAddress) external whenInitialized onlyRole(DEFAULT_ADMIN_ROLE) {
        _token = ERC20Upgradeable(tokenAddress);
    }

    function getTokenAddress() external view whenInitialized onlyRole(DEFAULT_ADMIN_ROLE) returns (address) {
        return address(_token);
    }
    //Initialization related

    function initialize() public initializer {
        __Ownable_init_unchained();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __NSFWFreezableUpgradable_init();
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
        require(!initialized, "Contract is initialized");
        _;
    }

    modifier whenInitialized {
        require(initialized, "Contract is not initialized");
        _;
    }
}
