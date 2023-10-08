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
    // === Slot 1 === // 160 + 32 + 32 + 8 + 16 + 8
    address worker;
    // Deposit
    uint32 compressedMinimumDeposit;
    uint32 compressedCapacity;
    bool isDepositPaused;
    // Withdraw
    uint16 withdrawalFeeBps;
    bool isWithdrawalPaused;
    // === Slot 2 === // 160 + 32 + 40
    address executor;
    // Management fee
    uint32 managementFeePerSec;
    uint40 lastManagementFeeCollectedAt;
    // === Slot 3 === // 160 + 16 + 8
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
  mapping(address => bool) public workerExisted; // worker address => is existed
  mapping(address => bool) public isExemptWithdrawalFee;

  ///////////////
  // Modifiers //
  ///////////////
  modifier collectManagementFee(address _vaultToken) {
    uint256 _lastCollectedFee = vaultInfos[_vaultToken].lastManagementFeeCollectedAt;
    if (block.timestamp > _lastCollectedFee) {
      uint256 _pendingFee = pendingManagementFee(_vaultToken);
      IAutomatedVaultERC20(_vaultToken).mint(managementFeeTreasury, _pendingFee);
      vaultInfos[_vaultToken].lastManagementFeeCollectedAt = uint40(block.timestamp);
    }
    _;
  }

  modifier onlyExistedVault(address _vaultToken) {
    if (vaultInfos[_vaultToken].worker == address(0)) {
      revert AutomatedVaultManager_VaultNotExist(_vaultToken);
    }
    _;
  }

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address _vaultTokenImplementation, address _managementFeeTreasury, address _withdrawalFeeTreasury)
    external
    initializer
  {
    if (
      _vaultTokenImplementation == address(0) || _managementFeeTreasury == address(0)
        || _withdrawalFeeTreasury == address(0)
    ) {
      revert AutomatedVaultManager_InvalidParams();
    }

    Ownable2StepUpgradeable.__Ownable2Step_init();
    ReentrancyGuardUpgradeable.__ReentrancyGuard_init();

    vaultTokenImplementation = _vaultTokenImplementation;
    managementFeeTreasury = _managementFeeTreasury;
    withdrawalFeeTreasury = _withdrawalFeeTreasury;
  }

  /// @notice Calculate pending management fee
  /// @dev Return as share amount
  /// @param _vaultToken an address of vault token
  /// @return _pendingFee an amount of share pending for minting as a form of management fee
  function pendingManagementFee(address _vaultToken) public view returns (uint256 _pendingFee) {
    uint256 _lastCollectedFee = vaultInfos[_vaultToken].lastManagementFeeCollectedAt;

    if (block.timestamp > _lastCollectedFee) {
      unchecked {
        _pendingFee = (
          IAutomatedVaultERC20(_vaultToken).totalSupply() * vaultInfos[_vaultToken].managementFeePerSec
            * (block.timestamp - _lastCollectedFee)
        ) / 1e18;
      }
    }
  }

  function deposit(address _depositFor, address _vaultToken, TokenAmount[] calldata _depositParams, uint256 _minReceive)
    external
    onlyExistedVault(_vaultToken)
    collectManagementFee(_vaultToken)
    nonReentrant
    returns (bytes memory _result)
  {
    VaultInfo memory _cachedVaultInfo = vaultInfos[_vaultToken];

    if (_cachedVaultInfo.isDepositPaused) {
      revert AutomatedVaultManager_EmergencyPaused();
    }

    _pullTokens(_vaultToken, _cachedVaultInfo.executor, _depositParams);

    ///////////////////////////
    // Executor scope opened //
    ///////////////////////////
    EXECUTOR_IN_SCOPE = _cachedVaultInfo.executor;
    // Accrue interest and reinvest before execute to ensure fair interest and profit distribution
    IExecutor(_cachedVaultInfo.executor).onUpdate(_cachedVaultInfo.worker, _vaultToken);

    (uint256 _totalEquityBefore,) =
      IVaultOracle(_cachedVaultInfo.vaultOracle).getEquityAndDebt(_vaultToken, _cachedVaultInfo.worker);

    _result = IExecutor(_cachedVaultInfo.executor).onDeposit(_cachedVaultInfo.worker, _vaultToken);
    EXECUTOR_IN_SCOPE = address(0);
    ///////////////////////////
    // Executor scope closed //
    ///////////////////////////

    uint256 _equityChanged;
    {
      (uint256 _totalEquityAfter, uint256 _debtAfter) =
        IVaultOracle(_cachedVaultInfo.vaultOracle).getEquityAndDebt(_vaultToken, _cachedVaultInfo.worker);
      if (_totalEquityAfter + _debtAfter > _cachedVaultInfo.compressedCapacity * CAPACITY_SCALE) {
        revert AutomatedVaultManager_ExceedCapacity();
      }
      _equityChanged = _totalEquityAfter - _totalEquityBefore;
    }

    if (_equityChanged < _cachedVaultInfo.compressedMinimumDeposit * MINIMUM_DEPOSIT_SCALE) {
      revert AutomatedVaultManager_BelowMinimumDeposit();
    }

    uint256 _shareReceived =
      _equityChanged.valueToShare(IAutomatedVaultERC20(_vaultToken).totalSupply(), _totalEquityBefore);
    if (_shareReceived < _minReceive) {
      revert AutomatedVaultManager_TooLittleReceived();
    }
    IAutomatedVaultERC20(_vaultToken).mint(_depositFor, _shareReceived);

    emit LogDeposit(_vaultToken, _depositFor, _depositParams, _shareReceived, _equityChanged);
  }

  function manage(address _vaultToken, bytes[] calldata _executorParams)
    external
    collectManagementFee(_vaultToken)
    nonReentrant
    returns (bytes[] memory _result)
  {
    // 0. Validate
    if (!isManager[_vaultToken][msg.sender]) {
      revert AutomatedVaultManager_Unauthorized();
    }

    VaultInfo memory _cachedVaultInfo = vaultInfos[_vaultToken];

    ///////////////////////////
    // Executor scope opened //
    ///////////////////////////
    EXECUTOR_IN_SCOPE = _cachedVaultInfo.executor;
    // 1. Update the vault
    // Accrue interest and reinvest before execute to ensure fair interest and profit distribution
    IExecutor(_cachedVaultInfo.executor).onUpdate(_cachedVaultInfo.worker, _vaultToken);

    // 2. execute manage
    (uint256 _totalEquityBefore,) =
      IVaultOracle(_cachedVaultInfo.vaultOracle).getEquityAndDebt(_vaultToken, _cachedVaultInfo.worker);

    // Set executor execution scope (worker, vault token) so that we don't have to pass them through multicall
    IExecutor(_cachedVaultInfo.executor).setExecutionScope(_cachedVaultInfo.worker, _vaultToken);
    _result = IExecutor(_cachedVaultInfo.executor).multicall(_executorParams);
    IExecutor(_cachedVaultInfo.executor).sweepToWorker();
    IExecutor(_cachedVaultInfo.executor).setExecutionScope(address(0), address(0));

    EXECUTOR_IN_SCOPE = address(0);
    ///////////////////////////
    // Executor scope closed //
    ///////////////////////////

    // 3. Check equity loss < threshold
    (uint256 _totalEquityAfter, uint256 _debtAfter) =
      IVaultOracle(_cachedVaultInfo.vaultOracle).getEquityAndDebt(_vaultToken, _cachedVaultInfo.worker);

    // _totalEquityAfter  < _totalEquityBefore * _cachedVaultInfo.toleranceBps / MAX_BPS;
    if (_totalEquityAfter * MAX_BPS < _totalEquityBefore * _cachedVaultInfo.toleranceBps) {
      revert AutomatedVaultManager_TooMuchEquityLoss();
    }

    // 4. Check leverage exceed max leverage
    // (debt + equity) / equity > max leverage
    // debt + equity = max leverage * equity
    // debt = (max leverage * equity) - equity
    // debt = (leverage - 1) * equity
    if (_debtAfter > (_cachedVaultInfo.maxLeverage - 1) * _totalEquityAfter) {
      revert AutomatedVaultManager_TooMuchLeverage();
    }

    emit LogManage(_vaultToken, _executorParams, _totalEquityBefore, _totalEquityAfter);
  }

  function withdraw(address _vaultToken, uint256 _sharesToWithdraw, TokenAmount[] calldata _minAmountOuts)
    external
    onlyExistedVault(_vaultToken)
    collectManagementFee(_vaultToken)
    nonReentrant
    returns (AutomatedVaultManager.TokenAmount[] memory _results)
{
    VaultInfo memory _cachedVaultInfo = vaultInfos[_vaultToken];

    if (_cachedVaultInfo.isWithdrawalPaused) {
        revert AutomatedVaultManager_EmergencyPaused();
    }

    // Revert if withdraw shares more than balance
    if (_sharesToWithdraw > IAutomatedVaultERC20(_vaultToken).balanceOf(msg.sender)) {
        revert AutomatedVaultManager_WithdrawExceedBalance();
    }

    uint256 _actualWithdrawAmount;
    // Safe to do unchecked because we already checked withdraw amount < balance and max bps won't overflow anyway
    unchecked {
        _actualWithdrawAmount = isExemptWithdrawalFee[msg.sender]
            ? _sharesToWithdraw
            : (_sharesToWithdraw * (MAX_BPS - _cachedVaultInfo.withdrawalFeeBps)) / MAX_BPS;
    }

    ///////////////////////////
    // Executor scope opened //
    ///////////////////////////
    EXECUTOR_IN_SCOPE = _cachedVaultInfo.executor;

    // Accrue interest and reinvest before execute to ensure fair interest and profit distribution
    IExecutor(_cachedVaultInfo.executor).onUpdate(_cachedVaultInfo.worker, _vaultToken);

    (uint256 _totalEquityBefore,) =
        IVaultOracle(_cachedVaultInfo.vaultOracle).getEquityAndDebt(_vaultToken, _cachedVaultInfo.worker);

    // Execute withdraw
    // Executor should send withdrawn funds back here to check slippage
    _results =
        IExecutor(_cachedVaultInfo.executor).onWithdraw(_cachedVaultInfo.worker, _vaultToken, _actualWithdrawAmount);

    EXECUTOR_IN_SCOPE = address(0);
    ///////////////////////////
    // Executor scope closed //
    ///////////////////////////

    uint256 _equityChanged;
    {
        (uint256 _totalEquityAfter,) =
            IVaultOracle(_cachedVaultInfo.vaultOracle).getEquityAndDebt(_vaultToken, _cachedVaultInfo.worker);
        _equityChanged = _totalEquityBefore - _totalEquityAfter;
    }

    uint256 _withdrawalFee;
    // Safe to do unchecked because _actualWithdrawAmount < _sharesToWithdraw from above
    unchecked {
        _withdrawalFee = _sharesToWithdraw - _actualWithdrawAmount;
    }

    // Burn shares per requested amount before transfer out
    IAutomatedVaultERC20(_vaultToken).burn(msg.sender, _sharesToWithdraw);
    // Mint withdrawal fee to withdrawal treasury
    if (_withdrawalFee != 0) {
        IAutomatedVaultERC20(_vaultToken).mint(withdrawalFeeTreasury, _withdrawalFee);
    }
    // Net shares changed would be `_actualWithdrawAmount`

    // Transfer withdrawn funds to user
    // Tokens should be transferred from executor to here during `onWithdraw`
    {
        uint256 _len = _results.length;
        if (_minAmountOuts.length < _len) {
            revert AutomatedVaultManager_InvalidMinAmountOut();
        }
        for (uint256 _i; _i < _len; _i++) {
            address _token = _results[_i].token;
            uint256 _amount = _results[_i].amount;

            // revert result token != min amount token
            if (_token != _minAmountOuts[_i].token) {
                revert AutomatedVaultManager_TokenMismatch();
            }

            // Check slippage
            if (_amount < _minAmountOuts[_i].amount) {
                revert AutomatedVaultManager_TooLittleReceived();
            }

            ERC20(_token).safeTransfer(msg.sender, _amount);
        }
    }

    // Assume `tx.origin` is user for tracking purpose
    emit LogWithdraw(_vaultToken, tx.origin, _sharesToWithdraw, _withdrawalFee, _equityChanged);
}
