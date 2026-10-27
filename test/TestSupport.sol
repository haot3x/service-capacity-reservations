// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CapacityReservations} from "../src/CapacityReservations.sol";
import {DirectBookingMarket} from "../src/DirectBookingMarket.sol";
import {SignedBookingMarket} from "../src/SignedBookingMarket.sol";
import {MarketEscrow} from "../src/MarketEscrow.sol";
import {IReservationOrder} from "../src/interfaces/IReservationOrder.sol";

interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }
    function warp(uint256) external;
    function chainId(uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
    function expectRevert() external;
    function expectRevert(bytes4) external;
    function expectPartialRevert(bytes4) external;
    function addr(uint256) external returns (address);
    function sign(uint256, bytes32) external returns (uint8, bytes32, bytes32);
    function mockCall(address, bytes calldata, bytes calldata) external;
    function mockCallRevert(address, bytes calldata, bytes calldata) external;
    function clearMockedCalls() external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function label(address, string calldata) external;
    function readFile(string calldata) external view returns (string memory);
}

abstract contract TestSupport {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    event log_named_uint(string key, uint256 value);

    function eq(uint256 a, uint256 b) internal pure {
        require(a == b, "uint mismatch");
    }

    function eq(address a, address b) internal pure {
        require(a == b, "address mismatch");
    }

    function yes(bool a) internal pure {
        require(a, "expected true");
    }

    function no(bool a) internal pure {
        require(!a, "expected false");
    }
}

contract MockPaymentToken is ERC20 {
    // Modes deliberately violate the supported exact-transfer asset policy.
    uint8 public mode;
    address public hookTarget;
    bytes public hookData;
    bool public hookSucceeded;
    bytes4 public hookError;
    constructor() ERC20("Demo Token", "DEMO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setMode(uint8 value) external {
        mode = value;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (mode == 1) return false;
        _spendAllowance(from, msg.sender, amount);
        _transfer(from, to, amount);
        if (mode == 2 && amount > 0) _burn(to, 1);
        _hook();
        return true;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (mode == 1) return false;
        _transfer(msg.sender, to, amount);
        if (mode == 2 && amount > 0) _burn(to, 1);
        _hook();
        return true;
    }

    function _hook() private {
        if (hookTarget == address(0)) return;
        bytes memory result;
        (hookSucceeded, result) = hookTarget.call(hookData);
        if (result.length >= 4) hookError = bytes4(result);
    }
}

contract SigningWallet {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 digest, bytes calldata signature) external view returns (bytes4) {
        return ECDSA.recover(digest, signature) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract RevertingAdmissionMarket is DirectBookingMarket {
    error AdmissionUpdateFailed();
    constructor(CapacityReservations registry, IERC20 token) DirectBookingMarket(registry, token) {}

    function admit(uint256 id) public override {
        super.admit(id);
        revert AdmissionUpdateFailed();
    }
}

// Intentionally mutable order view, used only to test the registry's binding checks.
contract OrderHarness is IReservationOrder {
    CapacityReservations public immutable registry;
    mapping(uint256 => Binding) private _bindings;

    constructor(CapacityReservations registry_) {
        registry = registry_;
    }

    function hold(uint256 pool, address buyer, uint64 units, uint64 until, bytes32 request)
        external
        returns (uint256)
    {
        return registry.hold(pool, buyer, units, until, request);
    }

    function setBinding(uint256 id, Binding calldata binding) external {
        _bindings[id] = binding;
    }

    function reservationOrder(uint256 id) external view returns (Binding memory) {
        return _bindings[id];
    }

    function confirm(uint256 id, bytes32 orderId) external {
        registry.confirm(id, orderId);
    }

    function consume(address buyer, uint256 id, uint256 units, bytes calldata data) external returns (bool) {
        return registry.consume(buyer, id, units, data);
    }
}

abstract contract Fixture is TestSupport {
    CapacityReservations internal registry;
    MockPaymentToken internal token;
    DirectBookingMarket internal direct;
    SignedBookingMarket internal signedMarket;
    address internal constant PROVIDER = address(0xA11CE);
    address internal constant ALICE = address(0xB0B);
    uint256 internal constant BOB_KEY = 0xB0B123;
    address internal bob;
    uint64 internal constant START = 10_000;
    uint64 internal constant END = 20_000;
    uint64 internal constant DEADLINE = 30_000;
    uint256 internal constant PRICE = 100;
    uint256 internal poolId;

    function setUp() public virtual {
        vm.warp(1_000);
        bob = vm.addr(BOB_KEY);
        registry = new CapacityReservations();
        token = new MockPaymentToken();
        direct = new DirectBookingMarket(registry, token);
        signedMarket = new SignedBookingMarket(registry, token);
        address[] memory adapters = new address[](2);
        adapters[0] = address(direct);
        adapters[1] = address(signedMarket);
        vm.prank(PROVIDER);
        poolId = registry.createPool(config(), adapters);
        vm.startPrank(PROVIDER);
        direct.configure(poolId, PRICE, DEADLINE);
        signedMarket.configure(poolId, PRICE, DEADLINE);
        vm.stopPrank();
        fund(ALICE);
        fund(bob);
        vm.label(address(registry), "SharedInventory");
        vm.label(address(direct), "DirectMarket");
        vm.label(address(signedMarket), "SignedMarket");
    }

    function config() internal view returns (CapacityReservations.PoolConfig memory) {
        return CapacityReservations.PoolConfig(
            keccak256(bytes(vm.readFile("examples/research-report-v1.json"))),
            keccak256(bytes(vm.readFile("examples/booking-terms-v1.json"))),
            10,
            START,
            END,
            1_000
        );
    }

    function fund(address buyer) internal {
        token.mint(buyer, 100_000);
        vm.startPrank(buyer);
        token.approve(address(direct), type(uint256).max);
        token.approve(address(signedMarket), type(uint256).max);
        vm.stopPrank();
    }

    function holdDirect(uint64 units) internal returns (uint256 id) {
        vm.prank(ALICE);
        id = direct.hold(poolId, units, uint64(block.timestamp + 500));
    }

    function book(uint64 units) internal returns (uint256 id) {
        id = holdDirect(units);
        vm.prank(ALICE);
        direct.confirm(id);
    }

    function request(uint64 units) internal view returns (SignedBookingMarket.HoldRequest memory) {
        return SignedBookingMarket.HoldRequest(
            bob,
            poolId,
            units,
            uint64(block.timestamp + 500),
            signedMarket.nonces(bob),
            uint64(block.timestamp + 400)
        );
    }

    function signature(SignedBookingMarket market, SignedBookingMarket.HoldRequest memory req)
        internal
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(BOB_KEY, market.holdDigest(req));
        return abi.encodePacked(r, s, v);
    }

    function status(uint256 id, CapacityReservations.Status expected) internal view {
        eq(uint256(registry.getReservation(id).status), uint256(expected));
    }

    function available() internal view returns (uint256 units) {
        (units,) = registry.availability(poolId);
    }

    function assertAccounting() internal view {
        CapacityReservations.Pool memory pool = registry.getPool(poolId);
        eq(available() + pool.held + pool.confirmed + pool.consumed, 10);
        eq(registry.totalSupply(), 10 - pool.consumed);
        eq(token.balanceOf(address(direct)), direct.escrowLiability());
        eq(token.balanceOf(address(signedMarket)), signedMarket.escrowLiability());
    }
}
