// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {FinalityCodec} from "@chainlink/contracts-ccip/contracts/libraries/FinalityCodec.sol";

library FinalityConfigUtils {
    // Access the forge-std vm cheatcode from within a library.
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Returns a human-readable label for a bytes4 finality config value.
    function decodeModeLabel(bytes4 config) internal pure returns (string memory) {
        if (config == FinalityCodec.WAIT_FOR_FINALITY_FLAG) {
            return "WAIT_FOR_FINALITY (default -- disables fast finality)";
        }
        if (config == FinalityCodec.WAIT_FOR_SAFE_FLAG) {
            return "WAIT_FOR_SAFE";
        }
        uint16 depth = uint16(uint32(config & FinalityCodec.BLOCK_DEPTH_MASK));
        uint32 flags = uint32(config) >> FinalityCodec.BLOCK_DEPTH_BITS;
        if (depth > 0 && flags == 0) {
            return string.concat("BLOCK_DEPTH (", vm.toString(depth), " blocks)");
        }
        if (depth > 0 && flags == 1) {
            return string.concat("WAIT_FOR_SAFE + BLOCK_DEPTH (", vm.toString(depth), " blocks)");
        }
        return "Custom / Reserved flags";
    }

    /// @notice Logs a bytes4 finality config value with its raw encoding, mode label, and description.
    function logFinalityConfig(bytes4 config) internal pure {
        console.log(string.concat("Allowed Finality Config (raw): ", vm.toString(abi.encodePacked(config))));
        console.log("");
        if (config == FinalityCodec.WAIT_FOR_FINALITY_FLAG) {
            console.log("Mode: WAIT_FOR_FINALITY (default)");
            console.log("  Full finality is required. Fast finality transfers are disabled.");
        } else if (config == FinalityCodec.WAIT_FOR_SAFE_FLAG) {
            console.log("Mode: WAIT_FOR_SAFE");
            console.log("  Fast finality transfers wait for the `safe` head.");
        } else {
            uint16 depth = uint16(uint32(config & FinalityCodec.BLOCK_DEPTH_MASK));
            uint32 flags = uint32(config) >> FinalityCodec.BLOCK_DEPTH_BITS;
            if (depth > 0 && flags == 0) {
                console.log(string.concat("Mode: BLOCK_DEPTH (", vm.toString(depth), " blocks)"));
                console.log("  Fast finality transfers wait for the configured number of block confirmations.");
            } else if (depth > 0 && flags == 1) {
                console.log(string.concat("Mode: WAIT_FOR_SAFE + BLOCK_DEPTH (", vm.toString(depth), " blocks)"));
                console.log("  The pool accepts either the `safe` head or the configured block depth.");
            } else {
                console.log("Mode: Custom / Reserved flags");
                console.log("  See the FinalityCodec library for encoding details.");
            }
        }
    }
}
