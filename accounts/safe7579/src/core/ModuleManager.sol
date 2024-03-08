// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { SentinelListLib } from "sentinellist/SentinelList.sol";
import { SentinelList4337Lib } from "sentinellist/SentinelList4337.sol";
import { IModule } from "erc7579/interfaces/IERC7579Module.sol";
import { ExecutionHelper } from "./ExecutionHelper.sol";
import { Receiver } from "erc7579/core/Receiver.sol";
import { AccessControl } from "./AccessControl.sol";
import { CallType, CALLTYPE_SINGLE, CALLTYPE_DELEGATECALL } from "erc7579/lib/ModeLib.sol";

CallType constant CALLTYPE_STATIC = CallType.wrap(0xFE);

struct FallbackHandler {
    address handler;
    CallType calltype;
}

struct ModuleManagerStorage {
    // linked list of executors. List is initialized by initializeAccount()
    SentinelListLib.SentinelList _executors;
    mapping(bytes4 selector => FallbackHandler fallbackHandler) _fallbacks;
}

/**
 * @title ModuleManager
 * Contract that implements ERC7579 Module compatibility for Safe accounts
 * @author zeroknots.eth | rhinestone.wtf
 */
abstract contract ModuleManager is AccessControl, Receiver, ExecutionHelper {
    using SentinelListLib for SentinelListLib.SentinelList;
    using SentinelList4337Lib for SentinelList4337Lib.SentinelList;

    error InvalidModule(address module);
    error LinkedListError();
    error CannotRemoveLastValidator();
    error InitializerError();
    error ValidatorStorageHelperError();
    error NoFallbackHandler(bytes4 msgSig);

    mapping(address smartAccount => ModuleManagerStorage moduleManagerStorage) internal
        $moduleManager;

    SentinelList4337Lib.SentinelList internal $validators;

    modifier onlyExecutorModule() {
        if (!_isExecutorInstalled(_msgSender())) revert InvalidModule(_msgSender());
        _;
    }

    /**
     * Initializes linked list that handles installed Validator and Executor
     */
    function _initModuleManager() internal {
        ModuleManagerStorage storage $mms = $moduleManager[msg.sender];
        // this will revert if list is already initialized
        $validators.init({ account: msg.sender });
        $mms._executors.init();
    }

    /////////////////////////////////////////////////////
    //  Manage Validators
    ////////////////////////////////////////////////////
    /**
     * install and initialize validator module
     */
    function _installValidator(address validator, bytes memory data) internal virtual {
        $validators.push({ account: msg.sender, newEntry: validator });

        // Initialize Validator Module via Safe
        _execute({
            safe: msg.sender,
            target: validator,
            value: 0,
            callData: abi.encodeCall(IModule.onInstall, (data))
        });
    }

    /**
     * Uninstall and de-initialize validator module
     */
    function _uninstallValidator(address validator, bytes memory data) internal {
        (address prev, bytes memory disableModuleData) = abi.decode(data, (address, bytes));
        $validators.pop({ account: msg.sender, prevEntry: prev, popEntry: validator });

        // De-Initialize Validator Module via Safe
        _execute({
            safe: msg.sender,
            target: validator,
            value: 0,
            callData: abi.encodeCall(IModule.onUninstall, (disableModuleData))
        });
    }

    /**
     * Helper function that will calculate storage slot for
     * validator address within the linked list in ValidatorStorageHelper
     * and use Safe's getStorageAt() to read 32bytes from Safe's storage
     */
    function _isValidatorInstalled(address validator)
        internal
        view
        virtual
        returns (bool isInstalled)
    {
        isInstalled = $validators.contains({ account: msg.sender, entry: validator });
    }

    function getValidatorPaginated(
        address start,
        uint256 pageSize
    )
        external
        view
        virtual
        returns (address[] memory array, address next)
    {
        return $validators.getEntriesPaginated({
            account: msg.sender,
            start: start,
            pageSize: pageSize
        });
    }

    /////////////////////////////////////////////////////
    //  Manage Executors
    ////////////////////////////////////////////////////

    function _installExecutor(address executor, bytes memory data) internal {
        SentinelListLib.SentinelList storage $executors = $moduleManager[msg.sender]._executors;
        $executors.push(executor);
        // Initialize Executor Module via Safe
        _execute({
            safe: msg.sender,
            target: executor,
            value: 0,
            callData: abi.encodeCall(IModule.onInstall, (data))
        });
    }

    function _uninstallExecutor(address executor, bytes calldata data) internal {
        SentinelListLib.SentinelList storage $executors = $moduleManager[msg.sender]._executors;
        (address prev, bytes memory disableModuleData) = abi.decode(data, (address, bytes));
        $executors.pop(prev, executor);

        // De-Initialize Executor Module via Safe
        _execute({
            safe: msg.sender,
            target: executor,
            value: 0,
            callData: abi.encodeCall(IModule.onUninstall, (disableModuleData))
        });
    }

    function _isExecutorInstalled(address executor) internal view virtual returns (bool) {
        SentinelListLib.SentinelList storage $executors = $moduleManager[msg.sender]._executors;
        return $executors.contains(executor);
    }

    function getExecutorsPaginated(
        address cursor,
        uint256 size
    )
        external
        view
        virtual
        returns (address[] memory array, address next)
    {
        SentinelListLib.SentinelList storage $executors = $moduleManager[msg.sender]._executors;
        return $executors.getEntriesPaginated(cursor, size);
    }

    /////////////////////////////////////////////////////
    //  Manage Fallback
    ////////////////////////////////////////////////////
    function _installFallbackHandler(address handler, bytes calldata params) internal virtual {
        (bytes4 functionSig, CallType calltype, bytes memory initData) =
            abi.decode(params, (bytes4, CallType, bytes));
        if (_isFallbackHandlerInstalled(functionSig)) revert();

        FallbackHandler storage $fallbacks = $moduleManager[msg.sender]._fallbacks[functionSig];
        $fallbacks.calltype = calltype;
        $fallbacks.handler = handler;

        //
        // ModuleManagerStorage storage $mms = $moduleManager[msg.sender];
        // $mms.fallbackHandler = handler;
        // // Initialize Fallback Module via Safe
        _execute({
            safe: msg.sender,
            target: handler,
            value: 0,
            callData: abi.encodeCall(IModule.onInstall, (initData))
        });
    }

    function _isFallbackHandlerInstalled(bytes4 functionSig) internal view virtual returns (bool) {
        FallbackHandler storage $fallback = $moduleManager[msg.sender]._fallbacks[functionSig];
        return $fallback.handler != address(0);
    }

    function _uninstallFallbackHandler(address handler, bytes calldata initData) internal virtual {
        (bytes4 functionSig) = abi.decode(initData, (bytes4));

        ModuleManagerStorage storage $mms = $moduleManager[msg.sender];
        $mms._fallbacks[functionSig].handler = address(0);
        // De-Initialize Fallback Module via Safe
        _execute({
            safe: msg.sender,
            target: handler,
            value: 0,
            callData: abi.encodeCall(IModule.onUninstall, (initData))
        });
    }

    function _isFallbackHandlerInstalled(
        address _handler,
        bytes calldata additionalContext
    )
        internal
        view
        virtual
        returns (bool)
    {
        bytes4 functionSig = abi.decode(additionalContext, (bytes4));

        FallbackHandler storage $fallback = $moduleManager[msg.sender]._fallbacks[functionSig];
        return $fallback.handler == _handler;
    }

    // FALLBACK
    // solhint-disable-next-line no-complex-fallback
    fallback() external payable override(Receiver) receiverFallback {
        FallbackHandler storage $fallbackHandler = $moduleManager[msg.sender]._fallbacks[msg.sig];
        address handler = $fallbackHandler.handler;
        CallType calltype = $fallbackHandler.calltype;
        if (handler == address(0)) revert NoFallbackHandler(msg.sig);

        if (calltype == CALLTYPE_STATIC) {
            assembly {
                function allocate(length) -> pos {
                    pos := mload(0x40)
                    mstore(0x40, add(pos, length))
                }

                let calldataPtr := allocate(calldatasize())
                calldatacopy(calldataPtr, 0, calldatasize())

                // The msg.sender address is shifted to the left by 12 bytes to remove the padding
                // Then the address without padding is stored right after the calldata
                let senderPtr := allocate(20)
                mstore(senderPtr, shl(96, caller()))

                // Add 20 bytes for the address appended add the end
                let success :=
                    staticcall(gas(), handler, calldataPtr, add(calldatasize(), 20), 0, 0)

                let returnDataPtr := allocate(returndatasize())
                returndatacopy(returnDataPtr, 0, returndatasize())
                if iszero(success) { revert(returnDataPtr, returndatasize()) }
                return(returnDataPtr, returndatasize())
            }
        }
        if (calltype == CALLTYPE_SINGLE) {
            assembly {
                function allocate(length) -> pos {
                    pos := mload(0x40)
                    mstore(0x40, add(pos, length))
                }

                let calldataPtr := allocate(calldatasize())
                calldatacopy(calldataPtr, 0, calldatasize())

                // The msg.sender address is shifted to the left by 12 bytes to remove the padding
                // Then the address without padding is stored right after the calldata
                let senderPtr := allocate(20)
                mstore(senderPtr, shl(96, caller()))

                // Add 20 bytes for the address appended add the end
                let success := call(gas(), handler, 0, calldataPtr, add(calldatasize(), 20), 0, 0)

                let returnDataPtr := allocate(returndatasize())
                returndatacopy(returnDataPtr, 0, returndatasize())
                if iszero(success) { revert(returnDataPtr, returndatasize()) }
                return(returnDataPtr, returndatasize())
            }
        }

        if (calltype == CALLTYPE_DELEGATECALL) {
            assembly {
                calldatacopy(0, 0, calldatasize())
                let result := delegatecall(gas(), handler, 0, calldatasize(), 0, 0)
                returndatacopy(0, 0, returndatasize())
                switch result
                case 0 { revert(0, returndatasize()) }
                default { return(0, returndatasize()) }
            }
        }
    }
}
