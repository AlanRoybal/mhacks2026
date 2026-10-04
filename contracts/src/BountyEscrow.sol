// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC20USDC {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Testnet job escrow. Only the arbiter registers terms and releases funds.
/// A poster (or the arbiter) can refund a funded job after its deadline.
contract BountyEscrow {
    enum State { EMPTY, REGISTERED, FUNDED, RELEASED, REFUNDED }
    struct Job { address poster; address worker; uint256 amount; uint64 deadline; State state; }
    address public immutable token;
    address public immutable arbiter;
    mapping(bytes32 => Job) public jobs;
    bool private entered;

    error Unauthorized();
    error InvalidTerms();
    error InvalidState();
    error TooEarly();
    error TransferFailed();
    error Reentrancy();

    event JobRegistered(bytes32 indexed jobId, address indexed poster, uint256 amount, uint64 deadline);
    event Deposited(bytes32 indexed jobId, address indexed poster, uint256 amount);
    event Released(bytes32 indexed jobId, address indexed worker, uint256 amount);
    event Refunded(bytes32 indexed jobId, address indexed poster, uint256 amount);

    constructor(address token_, address arbiter_) {
        if (token_.code.length == 0 || arbiter_ == address(0) || IERC20USDC(token_).decimals() != 6) revert InvalidTerms();
        token = token_;
        arbiter = arbiter_;
    }

    modifier onlyArbiter() { if (msg.sender != arbiter) revert Unauthorized(); _; }
    modifier nonReentrant() {
        if (entered) revert Reentrancy();
        entered = true;
        _;
        entered = false;
    }

    function registerJob(bytes32 jobId, address poster, uint256 amount, uint64 deadline) external onlyArbiter {
        if (jobId == bytes32(0) || poster == address(0) || amount == 0 || deadline <= block.timestamp) revert InvalidTerms();
        if (jobs[jobId].state != State.EMPTY) revert InvalidState();
        jobs[jobId] = Job(poster, address(0), amount, deadline, State.REGISTERED);
        emit JobRegistered(jobId, poster, amount, deadline);
    }

    function deposit(bytes32 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (msg.sender != job.poster) revert Unauthorized();
        if (job.state != State.REGISTERED || block.timestamp >= job.deadline) revert InvalidState();
        uint256 beforeBalance = IERC20USDC(token).balanceOf(address(this));
        job.state = State.FUNDED;
        safeTransfer(abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, address(this), job.amount));
        if (IERC20USDC(token).balanceOf(address(this)) != beforeBalance + job.amount) revert TransferFailed();
        emit Deposited(jobId, job.poster, job.amount);
    }

    function release(bytes32 jobId, address worker) external onlyArbiter nonReentrant {
        Job storage job = jobs[jobId];
        if (job.state != State.FUNDED) revert InvalidState();
        if (worker == address(0) || worker == address(this) || worker == job.poster) revert InvalidTerms();
        job.state = State.RELEASED;
        job.worker = worker;
        safeTransfer(abi.encodeWithSignature("transfer(address,uint256)", worker, job.amount));
        emit Released(jobId, worker, job.amount);
    }

    function refund(bytes32 jobId) external nonReentrant {
        Job storage job = jobs[jobId];
        if (msg.sender != job.poster && msg.sender != arbiter) revert Unauthorized();
        if (job.state != State.FUNDED) revert InvalidState();
        if (block.timestamp < job.deadline) revert TooEarly();
        job.state = State.REFUNDED;
        safeTransfer(abi.encodeWithSignature("transfer(address,uint256)", job.poster, job.amount));
        emit Refunded(jobId, job.poster, job.amount);
    }

    function safeTransfer(bytes memory data) private {
        (bool ok, bytes memory result) = token.call(data);
        if (!ok || (result.length != 0 && (result.length != 32 || !abi.decode(result, (bool))))) revert TransferFailed();
    }
}
