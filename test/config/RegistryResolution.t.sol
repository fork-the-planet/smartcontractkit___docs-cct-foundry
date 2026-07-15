// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {RegistryWriter} from "../../src/utils/RegistryWriter.sol";
import {ProjectScratch} from "../utils/ProjectScratch.sol";

/// @title RegistryResolutionTest
/// @notice Deployed-address resolution precedence in `HelperConfig`:
///         inline alias env (`TOKEN_POOL`) > chain-scoped env (`{CHAIN}_TOKEN_POOL`)
///         > project store `active.tokenPool` (`project/<selectorName>.json`) > `address(0)`.
/// @dev ONE test function: `vm.setEnv` is process-wide and forge runs tests in parallel, so the
///      env escalation must be strictly ordered inside a single function (env vars are only ever
///      escalated, never unset — the one-way discipline the existing fixtures use). This test proves
///      rungs 4→3→2 (nothing → store → chain-scoped) using CHAIN-SCOPED `{CHAIN}_TOKEN_POOL` vars on
///      chains no other suite touches.
///
///      **Rung 1 (the BARE inline `TOKEN_POOL` alias) is deliberately NOT asserted here.** The bare
///      alias is chain-AGNOSTIC and the HIGHEST-priority rung, and `vm.setEnv` is process-global and
///      never unset, so setting it would permanently smear across every parallel fork suite that
///      resolves a Sepolia pool through the same ladder — `SetupActions`' `SetPool.run()` would then
///      resolve THIS test's junk `INLINE_POOL` and revert (an observed, non-deterministic failure).
///      No bare-alias role is safe: `TOKEN`/`TOKEN_POOL`/`LOCK_BOX`/`POOL_HOOKS` are each read by some
///      fork script (deploy / set-pool / deposit-to-lockbox), and a persistent bare set poisons them.
///      The inline rung is a trivial one-line `vm.envOr("TOKEN_POOL", <chain-scoped>)` FIRST argument
///      — self-evident and shared verbatim across all four roles — so trading its micro-assertion for
///      deterministic parallelism is the correct call. `TOKEN` and `TOKEN_POOL` share the exact same
///      resolution code in `HelperConfig._initializeDeployedContracts`, so the ladder proven for
///      `TOKEN_POOL` holds for `TOKEN`. The store keys by selectorName (`project/<selectorName>.json`),
///      which `HelperConfig` resolves from the chainId via `getSelectorName`.
contract RegistryResolutionTest is Test {
    uint256 internal constant INK_SEPOLIA_CHAIN_ID = 763373;
    uint256 internal constant MANTLE_SEPOLIA_CHAIN_ID = 5003;
    uint256 internal constant PLUME_TESTNET_CHAIN_ID = 98867;

    string internal constant INK_SEL = "ink-testnet-sepolia";
    string internal constant MANTLE_SEL = "ethereum-testnet-sepolia-mantle-1";
    string internal constant PLUME_SEL = "plume-testnet-sepolia";

    address internal constant REGISTRY_POOL = address(uint160(0xA1));
    address internal constant CHAIN_ENV_POOL = address(uint160(0xB2));
    address internal constant BACKCOMPAT_POOL = address(uint160(0xD4));

    /// @dev Revert-safe cleanup: delete this suite's scratch project files BEFORE the test runs, never
    /// relying on end-of-test deletion. `project/*.json` is gitignored, so a file left behind by a
    /// mid-test revert survives invisibly (`git status` stays clean) and bricks every later `forge test`
    /// (the rung-4 preconditions assert the file is absent). Cleaning up front makes the suite idempotent.
    /// The real `config/chains/<name>.json` files stay (needed for chainId → selectorName resolution).
    function setUp() public {
        ProjectScratch.cleanProject(INK_SEL);
        ProjectScratch.cleanProject(MANTLE_SEL);
        ProjectScratch.cleanProject(PLUME_SEL);
    }

    function test_ResolutionPrecedence_ChainEnvOverRegistryOverZero() public {
        // Preconditions: the ladder is only observable when the relevant vars start unset
        // (skip instead of failing when the caller's shell already exports them). The bare `TOKEN_POOL`
        // check stays a precondition even though rung 1 is not asserted — a stray inline alias would
        // still mask the chain-scoped rungs below.
        if (
            vm.envOr("TOKEN_POOL", address(0)) != address(0)
                || vm.envOr("INK_SEPOLIA_TOKEN_POOL", address(0)) != address(0)
                || vm.envOr("MANTLE_SEPOLIA_TOKEN_POOL", address(0)) != address(0)
                || vm.envOr("PLUME_TESTNET_TOKEN_POOL", address(0)) != address(0)
        ) {
            vm.skip(true);
        }

        // Rung 4 — nothing anywhere: resolution stays address(0) (unchanged pre-store behavior).
        assertFalse(vm.exists(ProjectScratch.projectPath(PLUME_SEL)), "precondition: no plume project file");
        assertEq(
            new HelperConfig().getDeployedTokenPool(PLUME_TESTNET_CHAIN_ID),
            address(0),
            "absent everywhere must resolve to address(0)"
        );

        // Rung 3 — store only: the deploy-flow-written file resolves with ZERO env vars.
        RegistryWriter.set(INK_SEL, "tokenPool", REGISTRY_POOL);
        assertEq(
            new HelperConfig().getDeployedTokenPool(INK_SEPOLIA_CHAIN_ID),
            REGISTRY_POOL,
            "store entry must resolve when no env var is set"
        );

        // Back-compat — the pre-store env-var flow keeps working with NO project file present.
        assertFalse(vm.exists(ProjectScratch.projectPath(MANTLE_SEL)), "precondition: no mantle project file");
        vm.setEnv("MANTLE_SEPOLIA_TOKEN_POOL", vm.toString(BACKCOMPAT_POOL));
        assertEq(
            new HelperConfig().getDeployedTokenPool(MANTLE_SEPOLIA_CHAIN_ID),
            BACKCOMPAT_POOL,
            "old env-var flow must keep working without any project file"
        );

        // Rung 2 — chain-scoped env var beats the store. (Rung 1, the bare inline alias, is NOT set
        // here — see the contract natspec: a process-global bare `TOKEN_POOL` poisons parallel fork
        // suites, so the highest rung is left unasserted by design.)
        vm.setEnv("INK_SEPOLIA_TOKEN_POOL", vm.toString(CHAIN_ENV_POOL));
        assertEq(
            new HelperConfig().getDeployedTokenPool(INK_SEPOLIA_CHAIN_ID),
            CHAIN_ENV_POOL,
            "chain-scoped env var must beat the store"
        );
    }
}

/// @title RegistryResolutionExtrasTest
/// @notice The same deployed-address ladder, now proven for `lockBox` and `poolHooks`. The
///         `HelperConfig` getters resolve: inline alias > `{CHAIN}_` env > store `active.<role>`
///         > `address(0)`.
/// @dev Uses the 0g testnet chain (16602) — a configured chain NO other suite touches — so its
///      project file and chain-scoped env vars cannot race the ladder above (which uses ink/mantle/
///      plume) or the Sepolia fork fixtures. Rungs 2-4 are asserted directly here. Rung 1 (the bare
///      inline `LOCK_BOX` / `POOL_HOOKS` alias) is deliberately NOT set process-wide: the deploy/ops
///      fork fixtures consume the lockbox/hooks addresses via the CHAIN-SCOPED vars
///      (`LockboxOps` sets `ETHEREUM_SEPOLIA_LOCK_BOX`, not the bare `LOCK_BOX`), and no suite sets the
///      bare `LOCK_BOX`/`POOL_HOOKS` alias, so rungs 2-4 here are race-free. The inline rung (rung 1)
///      is intentionally NOT asserted anywhere (see `RegistryResolutionTest`'s natspec): a
///      process-global bare alias poisons parallel fork suites, and the rung is a trivial one-line
///      `vm.envOr("<ROLE>", <chain-scoped>)` first argument shared verbatim across all four roles.
contract RegistryResolutionExtrasTest is Test {
    uint256 internal constant ZERO_G_TESTNET_CHAIN_ID = 16602;
    string internal constant ZERO_G_SEL = "0g-testnet-galileo-1";
    string internal constant CHAIN_LOCK_BOX_ENV = "0G_GALILEO_TESTNET_LOCK_BOX";
    string internal constant CHAIN_POOL_HOOKS_ENV = "0G_GALILEO_TESTNET_POOL_HOOKS";

    address internal constant REG_LOCK_BOX = address(uint160(0xB0));
    address internal constant REG_POOL_HOOKS = address(uint160(0xB1));
    address internal constant CHAIN_LOCK_BOX = address(uint160(0xC0));
    address internal constant CHAIN_POOL_HOOKS = address(uint160(0xC1));

    /// @dev Revert-safe cleanup (see the sibling `RegistryResolutionTest.setUp`): delete the scratch
    /// `project/0g-testnet-galileo-1.json` BEFORE the precondition, so a mid-test revert can never leave
    /// a gitignored file that deterministically bricks the next `forge test` at "precondition: no 0g
    /// project file".
    function setUp() public {
        ProjectScratch.cleanProject(ZERO_G_SEL);
    }

    function test_LockBoxAndPoolHooks_ResolutionLadder() public {
        // Preconditions: observable only when the relevant vars start unset (skip, don't fail).
        if (
            vm.envOr("LOCK_BOX", address(0)) != address(0) || vm.envOr("POOL_HOOKS", address(0)) != address(0)
                || vm.envOr(CHAIN_LOCK_BOX_ENV, address(0)) != address(0)
                || vm.envOr(CHAIN_POOL_HOOKS_ENV, address(0)) != address(0)
        ) {
            vm.skip(true);
        }

        // Rung 4 — nothing anywhere: both resolve to address(0).
        assertFalse(vm.exists(ProjectScratch.projectPath(ZERO_G_SEL)), "precondition: no 0g project file");
        assertEq(new HelperConfig().getDeployedLockBox(ZERO_G_TESTNET_CHAIN_ID), address(0), "lockBox absent -> 0");
        assertEq(new HelperConfig().getDeployedPoolHooks(ZERO_G_TESTNET_CHAIN_ID), address(0), "poolHooks absent -> 0");

        // Rung 3 — store only (the deploy-flow-written active pointers) resolves with ZERO env vars.
        // This is the exact zero-export promise: after a lockbox/hooks deploy, later scripts resolve them.
        RegistryWriter.setActive(ZERO_G_SEL, "lockBox", REG_LOCK_BOX);
        RegistryWriter.setActive(ZERO_G_SEL, "poolHooks", REG_POOL_HOOKS);
        assertEq(
            new HelperConfig().getDeployedLockBox(ZERO_G_TESTNET_CHAIN_ID),
            REG_LOCK_BOX,
            "store active.lockBox resolves with no env var"
        );
        assertEq(
            new HelperConfig().getDeployedPoolHooks(ZERO_G_TESTNET_CHAIN_ID),
            REG_POOL_HOOKS,
            "store active.poolHooks resolves with no env var"
        );

        // Rung 2 — chain-scoped env var beats the store. These `{CHAIN}_` vars are 0g-specific, so
        // they cannot leak into the Sepolia fork fixtures.
        vm.setEnv(CHAIN_LOCK_BOX_ENV, vm.toString(CHAIN_LOCK_BOX));
        vm.setEnv(CHAIN_POOL_HOOKS_ENV, vm.toString(CHAIN_POOL_HOOKS));
        assertEq(
            new HelperConfig().getDeployedLockBox(ZERO_G_TESTNET_CHAIN_ID),
            CHAIN_LOCK_BOX,
            "chain-scoped env beats the store (lockBox)"
        );
        assertEq(
            new HelperConfig().getDeployedPoolHooks(ZERO_G_TESTNET_CHAIN_ID),
            CHAIN_POOL_HOOKS,
            "chain-scoped env beats the store (poolHooks)"
        );
    }
}
