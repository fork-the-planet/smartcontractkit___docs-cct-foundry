// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";

/// @title ProjectStore
/// @notice Path, skeleton, and schema helpers for the per-chain **project-state store**
/// `project/<selectorName>.json` — the single home for a chain's project state, three subtrees
/// (`addresses{}`, `lanes{}`, `roles{}`) plus a `schema` version, one writer each. The store keys by
/// the canonical CCIP **selectorName**, identical to `config/chains/<selectorName>.json` and
/// `history/<category>/<selectorName>/`, so the three files for a chain share one basename and
/// non-EVM chains (which all report chainId `"0"`) never collide.
///
/// @dev **Canonical form (project/ files): forge `vm.writeJson`'s deterministic output — keys
/// serialized in SORTED order at every nesting level, 2-space indent, and NO trailing newline.**
/// `vm.writeJson` preserves insertion order (it does not sort) and omits the trailing newline, so
/// every writer must insert keys already sorted; a golden test pins the result against
/// `jq --indent 2 -S` with the trailing newline normalized. `make fmt-config` extends here as the
/// REPAIR tool only. The project file is NEVER written with `vm.writeFile` (a whole-file write would
/// clobber sibling subtrees): data writes are targeted
/// `vm.writeJson(value, path, ".addresses"|".lanes"|".roles")`, and the file is bootstrapped with the
/// 2-arg `vm.writeJson(SKELETON, path)` create form only when absent.
///
/// Needs `fs_permissions` read-write on `./project` (covered by the repo's root permission).
library ProjectStore {
    /// @dev Well-known cheatcode address (forge-std pattern) so a library can reach `vm`.
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The project-state schema version. Future migrations dispatch on this integer rather
    /// than key-sniffing.
    uint256 internal constant SCHEMA = 3;

    /// @dev The canonical empty skeleton: all three subtrees + `schema`, keys in SORTED order
    /// (`addresses` < `lanes` < `roles` < `schema`; `active` < `deployments`) so forge's
    /// insertion-order `writeJson` emits sorted JSON with no post-processing.
    string internal constant SKELETON =
        "{\"addresses\":{\"active\":{},\"deployments\":{}},\"lanes\":{},\"roles\":{},\"schema\":3}";

    /// @notice `project/<selectorName>.json` under the project root.
    function path(string memory selectorName) internal view returns (string memory) {
        return string.concat(VM.projectRoot(), "/project/", selectorName, ".json");
    }

    /// @notice Bootstrap `project/<selectorName>.json` with the full skeleton when it does not yet
    /// exist, so the first targeted subtree write never hits a `vm.writeJson`-cannot-create-a-key
    /// cheatcode revert. A user's first touch of a chain is often `add-lane` or `snapshot-chain`, not
    /// a deploy, so EVERY writer (deploy-record, add-lane, snapshot-chain, adopt-token) calls this
    /// before its subtree write. Idempotent: an existing file is schema-validated and left
    /// byte-identical (never re-seeded over populated subtrees). Uses the 2-arg `vm.writeJson` create
    /// form — never `vm.writeFile` — and only when absent, so it can never clobber a sibling subtree.
    function seedIfAbsent(string memory selectorName) internal {
        string memory p = path(selectorName);
        if (VM.exists(p)) {
            requireSchema(selectorName);
            return;
        }
        VM.writeJson(SKELETON, p);
    }

    /// @notice Reverts with a NAMED error when `project/<selectorName>.json` is present but is not a
    /// schema-`SCHEMA` document (wrong version, missing `schema`, or not valid JSON) — never a raw
    /// `parseJson` cheatcode revert. Write paths and explicit readers (the doctor's schema rung,
    /// `roles-check`, `adopt-token`) call this; the OPTIONAL address-resolution fallback in
    /// `RegistryWriter.read*` stays tolerant (returns empty, never reverts) so an eager
    /// `HelperConfig` construction racing a parallel test's scratch file is never crashed.
    function requireSchema(string memory selectorName) internal view {
        string memory p = path(selectorName);
        if (!VM.exists(p)) return; // absent is a seed case, not a schema error
        string memory json = VM.readFile(p);
        require(bytes(json).length != 0, string.concat("[project] ", p, " is empty - not valid JSON; fix or delete it"));
        try VM.keyExistsJson(json, ".schema") returns (bool exists) {
            require(
                exists,
                string.concat(
                    "[project] ",
                    p,
                    " has no schema field - not a schema ",
                    VM.toString(SCHEMA),
                    " project file; fix or delete it"
                )
            );
        } catch {
            revert(string.concat("[project] ", p, " is not valid JSON - fix or delete it"));
        }
        uint256 s = VM.parseJsonUint(json, ".schema");
        require(
            s == SCHEMA,
            string.concat(
                "[project] ", p, " is schema ", VM.toString(s), " - unsupported, expected ", VM.toString(SCHEMA)
            )
        );
    }
}
