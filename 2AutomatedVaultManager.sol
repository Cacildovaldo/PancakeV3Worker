// SPDX-License-Identifier: BUSL
pragma solidity 0.8.19;

// dependencies
import { ERC20 } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/ERC20.sol";
import { SafeTransferLib } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/SafeTransferLib.sol";
import { Initializable } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/Initializable.sol";
import { Ownable2StepUpgradeable } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/Ownable2StepUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/ReentrancyGuardUpgradeable.sol";
import { ClonesUpgradeable } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/ClonesUpgradeable.sol";

// contracts
import { AutomatedVaultERC20 } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/AutomatedVaultERC20.sol";
import { BaseOracle } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/BaseOracle.sol";

// interfaces
import { IExecutor } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/IExecutor.sol";
import { IVaultOracle } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/IVaultOracle.sol";
import { IAutomatedVaultERC20 } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/IAutomatedVaultERC20.sol";

// libraries
import { LibShareUtil } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/LibShareUtil.sol";
import { MAX_BPS } from "https://github.com/Cacildovaldo/PancakeV3Worker/blob/tokens/Constants.sol";

contract AutomatedVaultManager is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    ///////////////
    // Libraries //
    ///////////////

    using SafeTransferLib for ERC20;
    using LibShareUtil for uint256;

    ////////////
    // Errors //
    ////////////

    error AutomatedVaultManager_InvalidMinAmountOut();
    error AutomatedVaultManager_TokenMismatch();
    error AutomatedVaultManager_VaultNotExist(address _vaultToken);
    error AutomatedVaultManager_WithdrawExceedBalance();
    error AutomatedVaultManager_Unauthorized();
    error AutomatedVaultManager_TooMuchEquityLoss();
    error AutomatedVaultManager_TooMuchLeverage();
    error AutomatedVaultManager_BelowMinimumDeposit();
    error AutomatedVaultManager_TooLittleReceived();
    error AutomatedVaultManager_TokenNotAllowed();
    error AutomatedVaultManager_InvalidParams();
    error AutomatedVaultManager_ExceedCapacity();
    error AutomatedVaultManager_EmergencyPaused();

    ////////////
    // Events //
    ////////////

    event LogOpenVault(address indexed _vaultToken, OpenVaultParams _vaultParams);
    event LogDeposit(
        address indexed _vaultToken,
        address indexed _user,
        TokenAmount[] _deposits,
        uint256 _shareReceived,
        uint256 _equityChanged
    );
    event LogWithdraw(
        address indexed _vaultToken,
        address indexed _user,
        uint256 _sharesWithdrawn,
        uint256 _withdrawFee,
        uint256 _equityChanged
    );
    event LogManage(address _vaultToken, bytes[] _executorParams, uint256 _equityBefore, uint256 _equityAfter);
    event LogSetVaultManager(address indexed _vaultToken, address _manager, bool _isOk);
    event LogSetAllowToken(address indexed _vaultToken, address _token, bool _isAllowed);
    event LogSetVaultTokenImplementation(address _prevImplementation, address _newImplementation);
    event LogSetToleranceBps(address _vaultToken, uint16 _toleranceBps);
    event LogSetMaxLeverage(address _vaultToken, uint8 _maxLeverage);
    event LogSetMinimumDeposit(address _vaultToken, uint32 _compressedMinimumDeposit);
    event LogSetManagementFeePerSec(address _vaultToken, uint32 _managementFeePerSec);
    event LogSetMangementFeeTreasury(address _managementFeeTreasury);
    event LogSetWithdrawalFeeTreasury(address _withdrawalFeeTreasury);
    event LogSetWithdrawalFeeBps(address _vaultToken, uint16 _withdrawalFeeBps);
    event LogSetCapacity(address _vaultToken, uint32 _compressedCapacity);
    event LogSetIsDepositPaused(address _vaultToken, bool _isPaused);
    event LogSetIsWithdrawPaused(address _vaultToken, bool _isPaused);
    event LogSetExemptWithdrawalFee(address _user, bool _isExempt);

    /////////////
    // Structs //
    /////////////

    struct TokenAmount {
        address token;
        uint256 amount;
    }

    struct VaultInfo {
        // === Slot 1 ===
        // 160 + 32 + 32 + 8 + 16 + 8
        address worker;
        // Deposit
        uint32 compressedMinimumDeposit;
        uint32 compressedCapacity;
        bool isDepositPaused;
        // Withdraw
        uint16 withdrawalFeeBps;
        bool isWithdrawalPaused;
        // === Slot 2 ===
        // 160 + 32 + 40
        address executor;
        // Management fee
        uint32 managementFeePerSec;
        uint40 lastManagementFeeCollectedAt;
        // === Slot 3 ===
        // 160 + 16 + 8
        address vaultOracle;
        // Manage
        uint16 toleranceBps;
        uint8 maxLeverage;
    }

    ///////////////
    // Constants //
    ///////////////

    uint256 constant MAX_MANAGEMENT_FEE_PER_SEC = 10e16 / uint256(365 days); // 10% per year
    uint256 constant MINIMUM_DEPOSIT_SCALE = 1e16; // 0.01 USD
    uint256 constant CAPACITY_SCALE = 1e18; // 1 USD

    /////////////////////
    // State variables //
    /////////////////////

    address public vaultTokenImplementation;
    address public managementFeeTreasury;
    address public withdrawalFeeTreasury;

    /// @dev execution scope to tell downstream contracts (Bank, Worker, etc.)
    /// that current executor is acting on behalf of vault and can be trusted
    address public EXECUTOR_IN_SCOPE;

    mapping(address => VaultInfo) public vaultInfos; // vault's ERC20 address => vault info
    mapping(address => mapping(address => bool)) public isManager; // vault's ERC20 address => manager address => is manager
    mapping(address => mapping(address => bool)) public allowTokens; // vault's ERC20 address => token address => is allowed