pragma solidity 0.5.16;

import "../node_modules/openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";

import "./Governance.sol";
import "./Verifier.sol";
import "./PriorityQueue.sol";
import "./Bytes.sol";
import "./Operations.sol";

/// @title Franklin Contract
/// @author Matter Labs
contract Franklin {
    /// @notice Verifier contract. Used to verify block proof and exit proof
    Verifier internal verifier;

    /// @notice Governance contract. Contains the governor (the owner) of whole system, validators list, possible tokens list
    Governance internal governance;

    /// @notice Priority Queue contract. Contains priority requests list
    PriorityQueue internal priorityQueue;

    /// @notice Franklin chain address length
    uint8 constant PUBKEY_HASH_BYTES = 20;

    /// @notice Public key bytes length
    uint8 constant PUBKEY_BYTES = 32;

    /// @notice Ethereum signature r/s bytes length
    uint8 constant ETH_SIGN_RS_BYTES = 32;

    /// @notice Success flag bytes length
    uint8 constant SUCCESS_FLAG_BYTES = 1;

    /// @notice Fee gas price for transactions
    uint256 constant FEE_GAS_PRICE_MULTIPLIER = 2; // 2 Gwei

    /// @notice Base gas for deposit eth transaction
    uint256 constant BASE_DEPOSIT_ETH_GAS = 179000;

    /// @notice Base gas for deposit erc20 transaction
    uint256 constant BASE_DEPOSIT_ERC_GAS = 214000;

    /// @notice Base gas for full exit transaction
    uint256 constant BASE_FULL_EXIT_GAS = 170000;

    /// @notice ETH blocks verification expectation
    uint256 constant EXPECT_VERIFICATION_IN = 8 * 60 * 100;

    /// @notice Max number of unverified blocks. To make sure that all reverted blocks can be copied under block gas limit!
    uint256 constant MAX_UNVERIFIED_BLOCKS = 4 * 60 * 100;

    uint256 constant NOOP_BYTES = 1 * 8;
    uint256 constant DEPOSIT_BYTES = 6 * 8;
    uint256 constant TRANSFER_TO_NEW_BYTES = 5 * 8;
    uint256 constant PARTIAL_EXIT_BYTES = 6 * 8;
    uint256 constant CLOSE_ACCOUNT_BYTES = 1 * 8;
    uint256 constant TRANSFER_BYTES = 2 * 8;
    
    /// @notice Full exit operation length
    uint256 constant FULL_EXIT_BYTES = 6 * 8;

    /// @notice ChangePubKey operation length
    uint256 constant CHANGE_PUBKEY_BYTES = 6 * 8;

    /// @notice Event emitted when a block is committed
    event BlockCommitted(uint32 indexed blockNumber);

    /// @notice Event emitted when a block is verified
    event BlockVerified(uint32 indexed blockNumber);

    /// @notice Event emitted when user send a transaction to withdraw her funds from onchain balance
    event OnchainWithdrawal(
        address indexed owner,
        uint16 tokenId,
        uint128 amount
    );

    /// @notice Event emitted when user send a transaction to deposit her funds
    event OnchainDeposit(
        address indexed owner,
        uint16 tokenId,
        uint128 amount,
        uint256 fee,
        bytes franklinAddress
    );

    event FactAuth(
        address sender,
        uint32 nonce,
        bytes fact
    );

    /// @notice Event emitted when blocks are reverted
    event BlocksReverted(
        uint32 indexed totalBlocksVerified,
        uint32 indexed totalBlocksCommitted
    );

    /// @notice Exodus mode entered event
    event ExodusMode();

    /// @notice Root-chain balances (per owner and token id) to withdraw
    mapping(address => mapping(uint16 => uint128)) public balancesToWithdraw;

    /// @notice verified withdrawal pending to be executed.
    struct PendingWithdrawal {
        address to;
        uint16 tokenId;
    }
    /// @notice Verified but not executed withdrawals for addresses stored in here
    mapping(uint32 => PendingWithdrawal) public pendingWithdrawals;
    uint32 public firstPendingWithdrawalIndex;
    uint32 public numberOfPendingWithdrawals;

    /// @notice Total number of verified blocks i.e. blocks[totalBlocksVerified] points at the latest verified block (block 0 is genesis)
    uint32 public totalBlocksVerified;

    /// @notice Total number of committed blocks i.e. blocks[totalBlocksCommitted] points at the latest committed block
    uint32 public totalBlocksCommitted;

    /// @notice Rollup block data (once per block)
    /// @member validator Block producer
    /// @member committedAtBlock ETH block number at which this block was committed
    /// @member operationStartId Index of the first operation to process for this block
    /// @member onchainOperations Total number of operations to process for this block
    /// @member priorityOperations Total number of priority operations for this block
    /// @member commitment Hash of the block circuit commitment
    /// @member stateRoot New tree root hash
    struct Block {
        address validator;
        uint32 committedAtBlock;
        uint64 operationStartId;
        uint64 onchainOperations;
        uint64 priorityOperations;
        bytes32 commitment;
        bytes32 stateRoot;
    }

    /// @notice Blocks by Franklin block id
    mapping(uint32 => Block) public blocks;

    /// @notice Onchain operations - operations processed inside rollup blocks
    /// @member opType Onchain operation type
    /// @member amount Amount used in the operation
    /// @member pubData Operation pubdata
    struct OnchainOperation {
        Operations.OpType opType;
        bytes pubData;
    }

    /// @notice Total number of registered onchain operations
    uint64 public totalOnchainOps;

    /// @notice Onchain operations by index
    mapping(uint64 => OnchainOperation) public onchainOps;

    /// @notice Flag indicates that a user has exited certain token balance (per owner and tokenId)
    mapping(address => mapping(uint16 => bool)) public exited;

    /// @notice Flag indicates that exodus (mass exit) mode is triggered
    /// @notice Once it was raised, it can not be cleared again, and all users must exit
    bool public exodusMode;

    /// @notice User authenticated facts for some nonce.
    mapping(address => mapping(uint32 => bytes)) public authFacts;

    // // Migration

    // // Address of the new version of the contract to migrate accounts to
    // // Can be proposed by network governor
    // address public migrateTo;

    // // Migration deadline: after this ETH block number migration may happen with the contract
    // // entering exodus mode for all users who have not opted in for migration
    // uint32  public migrateByBlock;

    // // Flag for the new contract to indicate that the migration has been sealed
    // bool    public migrationSealed;

    // mapping (uint32 => bool) tokenMigrated;

    /// @notice Constructs Franklin contract
    /// @param _governanceAddress The address of Governance contract
    /// @param _verifierAddress The address of Verifier contract
    /// @param _priorityQueueAddress The address of Priority Queue contract
    /// _genesisAccAddress The address of single account, that exists in genesis block
    /// @param _genesisRoot Genesis blocks (first block) root
    constructor(
        address _governanceAddress,
        address _verifierAddress,
        address _priorityQueueAddress,
        address, // FIXME: remove _genesisAccAddress
        bytes32 _genesisRoot
    ) public {
        verifier = Verifier(_verifierAddress);
        governance = Governance(_governanceAddress);
        priorityQueue = PriorityQueue(_priorityQueueAddress);

        blocks[0].stateRoot = _genesisRoot;
    }

    /// @notice executes pending withdrawals
    /// @param _n The number of withdrawals to complete starting from oldest
    function completeWithdrawals(uint32 _n) external {
        // TODO: when switched to multi valiators model we need to add insentive mechanism to call complete.
        uint32 toProcess = _n;
        if (toProcess > numberOfPendingWithdrawals) {
            toProcess = numberOfPendingWithdrawals;
        }
        uint32 startIndex = firstPendingWithdrawalIndex;
        numberOfPendingWithdrawals -= toProcess;
        if (numberOfPendingWithdrawals == 0) {
            firstPendingWithdrawalIndex = 0;
        } else {
            firstPendingWithdrawalIndex += toProcess;
        }

        for (uint32 i = startIndex; i < startIndex + toProcess; ++i) {
            uint16 tokenId = pendingWithdrawals[i].tokenId;
            address to = pendingWithdrawals[i].to;
            // send fails are ignored hence there is always a direct way to withdraw.
            delete pendingWithdrawals[i];

            uint128 amount = balancesToWithdraw[to][tokenId];
            // amount is zero means funds has been withdrawn with withdrawETH or withdrawERC20
            if (amount != 0) {
                // avoid reentrancy attack by using subtract and not "= 0" and changing local state before external call
                balancesToWithdraw[to][tokenId] -= amount;
                bool sent = false;
                if (tokenId == 0) {
                    address payable toPayable = address(uint160(to));
                    sent = toPayable.send(amount);
                } else if (governance.isValidTokenId(tokenId)) {
                    address tokenAddr = governance.tokenAddresses(tokenId);
                    sent = IERC20(tokenAddr).transfer(to, amount);
                }
                if (!sent) {
                    balancesToWithdraw[to][tokenId] += amount;
                }
            }
        }
    }

    /// @notice Collects fees from provided requests number for the block validator, store it on her
    /// @notice balance to withdraw in Ether and delete this requests
    /// @param _number The number of requests
    /// @param _validator The address to pay fees
    function collectValidatorsFeeAndDeleteRequests(uint64 _number, address _validator) internal {
        uint256 totalFee = priorityQueue.collectValidatorsFeeAndDeleteRequests(_number);
        balancesToWithdraw[_validator][0] += uint128(totalFee);
    }

    /// @notice Accrues users balances from deposit priority requests in Exodus mode
    /// @dev WARNING: Only for Exodus mode
    /// @dev Canceling may take several separate transactions to be completed
    /// @param _number Supposed number of requests to look at
    function cancelOutstandingDepositsForExodusMode(uint64 _number) external {
        require(exodusMode, "frc11");
        require(_number > 0, "frс12"); // provided zero number of requests

        bytes memory depositsPubData = priorityQueue.deletePriorityRequestsAndPopOutstandingDeposits(_number);
        uint offset = 0;
        while (offset < depositsPubData.length) {
            Operations.Deposit memory op;
            (offset, op) = Operations.readDepositPubdata(depositsPubData, offset);
            balancesToWithdraw[op.owner][op.tokenId] += op.amount;
        }
    }

    // function scheduleMigration(address _migrateTo, uint32 _migrateByBlock) external {
    //     requireGovernor();
    //     require(migrateByBlock == 0, "migration in progress");
    //     migrateTo = _migrateTo;
    //     migrateByBlock = _migrateByBlock;
    // }

    // // Anybody MUST be able to call this function
    // function sealMigration() external {
    //     require(migrateByBlock > 0, "no migration scheduled");
    //     migrationSealed = true;
    //     exodusMode = true;
    // }

    // // Anybody MUST be able to call this function
    // function migrateToken(uint32 _tokenId, uint128 /*_amount*/, bytes calldata /*_proof*/) external {
    //     require(migrationSealed, "migration not sealed");
    //     requireValidToken(_tokenId);
    //     require(tokenMigrated[_tokenId]==false, "token already migrated");
    //     // TODO: check the proof for the amount
    //     // TODO: transfer ERC20 or ETH to the `migrateTo` address
    //     tokenMigrated[_tokenId] = true;

    //     require(false, "unimplemented");
    // }

    /// @notice Deposit ETH to Layer 2 - transfer ether from user into contract, validate it, register deposit
    /// @param _amount Amount to deposit (if user specified msg.value more than this amount + fee - she will recieve difference)
    /// @param _franklinAddr The receiver Layer 2 address
    function depositETH(uint128 _amount, bytes calldata _franklinAddr) external payable {
        requireActive();

        // Fee is:
        //   fee coeff * base tx gas cost * gas price
        uint256 fee = FEE_GAS_PRICE_MULTIPLIER * BASE_DEPOSIT_ETH_GAS * tx.gasprice;

        require(msg.value >= fee + _amount, "fdh11"); // Not enough ETH provided

        if (msg.value != fee + _amount) {
            msg.sender.transfer(msg.value-(fee + _amount));
        }

        registerDeposit(0, _amount, fee, _franklinAddr);
    }

    /// @notice Withdraw ETH to Layer 1 - register withdrawal and transfer ether to sender
    /// @param _amount Ether amount to withdraw
    function withdrawETH(uint128 _amount) external {
        registerSingleWithdrawal(0, _amount);
        msg.sender.transfer(_amount);
    }

    /// @notice Deposit ERC20 token to Layer 2 - transfer ERC20 tokens from user into contract, validate it, register deposit
    /// @param _token Token address
    /// @param _amount Token amount
    /// @param _franklinAddr Receiver Layer 2 address
    function depositERC20(
        address _token,
        uint128 _amount,
        bytes calldata _franklinAddr
    ) external payable {
        requireActive();

        // Fee is:
        //   fee coeff * base tx gas cost * gas price
        uint256 fee = FEE_GAS_PRICE_MULTIPLIER * BASE_DEPOSIT_ERC_GAS * tx.gasprice;

        // Get token id by its address
        uint16 tokenId = governance.validateTokenAddress(_token);

        require(msg.value >= fee, "fd011"); // Not enough ETH provided to pay the fee
        require(IERC20(_token).transferFrom(msg.sender, address(this), _amount), "fd012"); // token transfer failed deposit

        registerDeposit(tokenId, _amount, fee, _franklinAddr);

        if (msg.value != fee) {
            msg.sender.transfer(msg.value-fee);
        }
    }

    /// @notice Withdraw ERC20 token to Layer 1 - register withdrawal and transfer ERC20 to sender
    /// @param _token Token address
    /// @param _amount amount to withdraw
    function withdrawERC20(address _token, uint128 _amount) external {
        uint16 tokenId = governance.validateTokenAddress(_token);
        registerSingleWithdrawal(tokenId, _amount);
        require(IERC20(_token).transfer(msg.sender, _amount), "fw011"); // token transfer failed withdraw
    }
    
    /// @notice Register full exit request - pack pubdata, add priority request
    /// @param _accountId Numerical id of the account
    /// @param _token Token address, 0 address for ether
    function fullExit (
        uint24 _accountId,
        address _token
    ) external payable {
        // Fee is:
        //   fee coeff * base tx gas cost * gas price
        uint256 fee = FEE_GAS_PRICE_MULTIPLIER * BASE_FULL_EXIT_GAS * tx.gasprice;
        
        uint16 tokenId;
        if (_token == address(0)) {
            tokenId = 0;
        } else {
            tokenId = governance.validateTokenAddress(_token);
        }
        
        require(msg.value >= fee, "fft11"); // Not enough ETH provided to pay the fee
        requireActive();

        // Priority Queue request
        Operations.FullExit memory op = Operations.FullExit({
            accountId:  _accountId,
            owner:      msg.sender,
            tokenId:    tokenId,
            amount:     0 // unknown at this point
        });
        bytes memory pubData = Operations.writeFullExitPubdata(op);
        priorityQueue.addPriorityRequest(uint8(Operations.OpType.FullExit), fee, pubData);

        if (msg.value != fee) {
            msg.sender.transfer(msg.value-fee);
        }
    }

    /// @notice Register deposit request - pack pubdata, add priority request and emit OnchainDeposit event
    /// @param _token Token by id
    /// @param _amount Token amount
    /// @param _fee Validator fee
    /// @param _franklinAddr Receiver
    function registerDeposit(
        uint16 _token,
        uint128 _amount,
        uint256 _fee,
        bytes memory _franklinAddr
    ) internal {
        require(_franklinAddr.length == PUBKEY_HASH_BYTES, "frd11"); // wrong franklin address hash
        
        // Priority Queue request
        Operations.Deposit memory op = Operations.Deposit({
            owner:      msg.sender,
            tokenId:    _token,
            amount:     _amount
        });
        bytes memory pubData = Operations.writeDepositPubdata(op);
        priorityQueue.addPriorityRequest(uint8(Operations.OpType.Deposit), _fee, pubData);

        emit OnchainDeposit(
            msg.sender,
            _token,
            _amount,
            _fee,
            _franklinAddr
        );
    }

    /// @notice Register withdrawal - update user balances and emit OnchainWithdrawal event
    /// @param _token - token by id
    /// @param _amount - token amount
    function registerSingleWithdrawal(uint16 _token, uint128 _amount) internal {
        require(balancesToWithdraw[msg.sender][_token] >= _amount, "frw11"); // insufficient balance withdraw

        balancesToWithdraw[msg.sender][_token] -= _amount;

        emit OnchainWithdrawal(
            msg.sender,
            _token,
            _amount
        );
    }

    /// @notice Commit block - collect onchain operations, create its commitment, emit BlockCommitted event
    /// @param _blockNumber Block number
    /// @param _feeAccount Account to collect fees
    /// @param _newRoot New tree root
    /// @param _publicData Operations pubdata
    /// @param _ethWitness Data passed to ethereum outside pubdata of the circuit.
    /// @param _ethWitnessSizes Amount of eth witness bytes for the corresponding operation.
    function commitBlock(
        uint32 _blockNumber,
        uint24 _feeAccount,
        bytes32 _newRoot,
        bytes calldata _publicData,
        bytes calldata _ethWitness,
        uint64[] calldata _ethWitnessSizes
    ) external {
        requireActive();
        require(_blockNumber == totalBlocksCommitted + 1, "fck11"); // only commit next block
        governance.requireActiveValidator(msg.sender);
        if(!triggerRevertIfBlockCommitmentExpired() && !triggerExodusIfNeeded()) {
            require(totalBlocksCommitted - totalBlocksVerified < MAX_UNVERIFIED_BLOCKS, "fck13"); // too many blocks committed
            
            // Unpack onchain operations and store them.
            // Get onchain operations start id for global onchain operations counter,
            // onchain operations number for this block, priority operations number for this block.
            uint64 startId = totalOnchainOps;
            (uint64 totalProcessed, uint64 priorityNumber) = collectOnchainOps(_publicData, _ethWitness, _ethWitnessSizes);

            // Verify that priority operations from this block are valid
            // (their data is similar to data from priority requests mapping)
            verifyPriorityOperations(startId, totalProcessed, priorityNumber);

            createCommittedBlock(_blockNumber, _feeAccount, _newRoot, _publicData, startId, totalProcessed, priorityNumber);

            totalOnchainOps = startId + totalProcessed;

            totalBlocksCommitted += 1;

            priorityQueue.increaseCommittedRequestsNumber(priorityNumber);

            emit BlockCommitted(_blockNumber);
        }
    }

    /// @notice Store committed block structure to the storage.
    /// @param _startId - blocks' onchain ops start id in global operations
    /// @param _totalProcessed - total number of onchain ops in block
    /// @param _priorityNumber - total number of priority onchain ops in block
    function createCommittedBlock(
        uint32 _blockNumber,
        uint24 _feeAccount,
        bytes32 _newRoot,
        bytes memory _publicData,
        uint64 _startId, uint64 _totalProcessed, uint64 _priorityNumber
    ) internal {
        // Create block commitment for verification proof
        bytes32 commitment = createBlockCommitment(
            _blockNumber,
            _feeAccount,
            blocks[_blockNumber - 1].stateRoot,
            _newRoot,
            _publicData
        );

        blocks[_blockNumber] = Block(
            msg.sender, // validator
            uint32(block.number), // committed at
            _startId, // blocks' onchain ops start id in global operations
            _totalProcessed, // total number of onchain ops in block
            _priorityNumber, // total number of priority onchain ops in block
            commitment, // blocks' commitment
            _newRoot // new root
        );
    }

    /// @notice Gets operations packed in bytes array. Unpacks it and stores onchain operations.
    /// @param _publicData Operations packed in bytes array
    /// @param _ethWitness Eth witness that was posted with commit
    /// @param _ethWitnessSizes Amount of eth witness bytes for the corresponding operation.
    /// @return onchain operations start id for global onchain operations counter, nchain operations number for this block, priority operations number for this block
    function collectOnchainOps(bytes memory _publicData, bytes memory _ethWitness, uint64[] memory _ethWitnessSizes)
        internal
        returns (uint64 processedOnchainOps, uint64 priorityCount)
    {
        require(_publicData.length % 8 == 0, "fcs11"); // pubdata length must be a multiple of 8 because each chunk is 8 bytes

        uint64 currentOnchainOp = totalOnchainOps;

        uint256 currentPointer = 0;

        // (current element, offset)
        uint64[2] memory currentEthWitness;

        while (currentPointer < _publicData.length) {
            uint8 opType = uint8(_publicData[currentPointer]);
            bytes memory currentEthWitnessBytes = Bytes.slice(_ethWitness, currentEthWitness[1], _ethWitnessSizes[currentEthWitness[0]]);
            (uint256 len, uint64 ops, uint64 priority) = processOp(
                opType,
                currentPointer,
                _publicData,
                currentOnchainOp,
                currentEthWitnessBytes
            );
            currentPointer += len;
            processedOnchainOps += ops;
            priorityCount += priority;
            currentOnchainOp += ops;

            currentEthWitness[1] += _ethWitnessSizes[currentEthWitness[0]];
            currentEthWitness[0] += 1;
        }
        require(currentPointer == _publicData.length, "fcs12"); // last chunk exceeds pubdata
    }

    function verifyChangePubkeySignature(bytes memory _signature, bytes memory _newPkHash, uint32 _nonce, address _ethAddress) internal pure returns (bool) {
        uint offset = 0;

        bytes32 signR = Bytes.bytesToBytes32(Bytes.slice(_signature, offset, ETH_SIGN_RS_BYTES));
        offset += ETH_SIGN_RS_BYTES;

        bytes32 signS = Bytes.bytesToBytes32(Bytes.slice(_signature, offset, ETH_SIGN_RS_BYTES));
        offset += ETH_SIGN_RS_BYTES;

        uint8 signV = uint8(_signature[offset]);

        bytes memory signedMessage = abi.encodePacked("\x19Ethereum Signed Message:\n24", _nonce, _newPkHash);
        address recoveredAddress = ecrecover(keccak256(signedMessage), signV, signR, signS);
        return recoveredAddress == _ethAddress;
    }

    /// @notice On the first byte determines the type of operation, if it is an onchain operation - saves it in storage
    /// @param _opType Operation type
    /// @param _currentPointer Current pointer in pubdata
    /// @param _publicData Operation pubdata
    /// @param _currentOnchainOp Operation identifier in onchain operations mapping
    /// @return operation processed length, and indicators if this operation is an onchain operation and if it is a priority operation (1 if true)
    function processOp(
        uint8 _opType,
        uint256 _currentPointer,
        bytes memory _publicData,
        uint64 _currentOnchainOp,
        bytes memory _currentEthWitness
    ) internal returns (uint256 processedLen, uint64 processedOnchainOps, uint64 priorityCount) {
        uint256 opDataPointer = _currentPointer + 1; // operation type byte

        if (_opType == uint8(Operations.OpType.Noop)) return (NOOP_BYTES, 0, 0);
        if (_opType == uint8(Operations.OpType.TransferToNew)) return (TRANSFER_TO_NEW_BYTES, 0, 0);
        if (_opType == uint8(Operations.OpType.Transfer)) return (TRANSFER_BYTES, 0, 0);
        if (_opType == uint8(Operations.OpType.CloseAccount)) return (CLOSE_ACCOUNT_BYTES, 0, 0);

        if (_opType == uint8(Operations.OpType.Deposit)) {
            bytes memory pubData = Bytes.slice(_publicData, opDataPointer, DEPOSIT_BYTES - 1);
            onchainOps[_currentOnchainOp] = OnchainOperation(
                Operations.OpType.Deposit,
                pubData
            );
            return (DEPOSIT_BYTES, 1, 1);
        }

        if (_opType == uint8(Operations.OpType.PartialExit)) {
            bytes memory pubData = Bytes.slice(_publicData, opDataPointer, PARTIAL_EXIT_BYTES - 1);
            onchainOps[_currentOnchainOp] = OnchainOperation(
                Operations.OpType.PartialExit,
                pubData
            );
            return (PARTIAL_EXIT_BYTES, 1, 0);
        }

        if (_opType == uint8(Operations.OpType.FullExit)) {
            bytes memory pubData = Bytes.slice(_publicData, opDataPointer, FULL_EXIT_BYTES - 1);
            onchainOps[_currentOnchainOp] = OnchainOperation(
                Operations.OpType.FullExit,
                pubData
            );
            return (FULL_EXIT_BYTES, 1, 1);
        }

        if (_opType == uint8(Operations.OpType.ChangePubKey)) {
            Operations.ChangePubKey memory op = Operations.readChangePubKeyPubdata(_publicData, opDataPointer);
            if (_currentEthWitness.length > 0) {
                bool valid = verifyChangePubkeySignature(_currentEthWitness, op.pubKeyHash, op.nonce, op.owner);
                require(valid, "fpp15"); // failed to verify change pubkey hash signature
            } else {
                bool valid = keccak256(authFacts[op.owner][op.nonce]) == keccak256(op.pubKeyHash);
                require(valid, "fpp16"); // new pub key hash is not authenticated properly
            }
            return (CHANGE_PUBKEY_BYTES, 0, 0);
        }

        revert("fpp14"); // unsupported op
    }
    
    /// @notice Creates block commitment from its data
    /// @param _blockNumber Block number
    /// @param _feeAccount Account to collect fees
    /// @param _oldRoot Old tree root
    /// @param _newRoot New tree root
    /// @param _publicData Operations pubdata
    /// @return block commitment
    function createBlockCommitment(
        uint32 _blockNumber,
        uint24 _feeAccount,
        bytes32 _oldRoot,
        bytes32 _newRoot,
        bytes memory _publicData
    ) internal pure returns (bytes32) {
        bytes32 hash = sha256(
            abi.encodePacked(uint256(_blockNumber), uint256(_feeAccount))
        );
        hash = sha256(abi.encodePacked(hash, uint256(_oldRoot)));
        hash = sha256(abi.encodePacked(hash, uint256(_newRoot)));
        // public data is committed with padding (TODO: check assembly and optimize to avoid copying data)
        hash = sha256(
            abi.encodePacked(
                hash,
                _publicData
            )
        );

        return hash;
    }

    /// @notice Check if blocks' priority operations are valid
    /// @param _startId Onchain op start id
    /// @param _totalProcessed How many ops are procceeded
    /// @param _number Priority ops number
    function verifyPriorityOperations(uint64 _startId, uint64 _totalProcessed, uint64 _number) internal view {
        priorityQueue.validateNumberOfRequests(_number);
        
        uint64 start = _startId;
        uint64 end = start + _totalProcessed;
        
        uint64 counter = 0;
        for (uint64 current = start; current < end; ++current) {
            if (onchainOps[current].opType == Operations.OpType.FullExit || onchainOps[current].opType == Operations.OpType.Deposit) {
                OnchainOperation storage op = onchainOps[current];
                require(priorityQueue.isPriorityOpValid(uint8(op.opType), op.pubData, counter), "fvs11"); // priority operation is not valid
                counter++;
            }
        }
    }

    /// @notice Removes some onchain ops (for example in case of wrong priority comparison)
    /// @param _startId Onchain op start id
    /// @param _totalProcessed How many ops are procceeded
    function revertOnchainOps(uint64 _startId, uint64 _totalProcessed) internal {
        uint64 start = _startId;
        uint64 end = start + _totalProcessed;

        for (uint64 current = start; current < end; ++current) {
            delete onchainOps[current];
        }
    }

    /// @notice Block verification.
    /// @notice Verify proof -> consummate onchain ops (accrue balances from withdrawls) -> remove priority requests
    /// @param _blockNumber Block number
    /// @param _proof Block proof
    function verifyBlock(uint32 _blockNumber, uint256[8] calldata _proof)
        external
    {
        requireActive();
        require(_blockNumber == totalBlocksVerified + 1, "fvk11"); // only verify next block
        governance.requireActiveValidator(msg.sender);

        require(verifier.verifyBlockProof(_proof, blocks[_blockNumber].commitment), "fvk13"); // proof verification failed

        consummateOnchainOps(_blockNumber);

        collectValidatorsFeeAndDeleteRequests(
            blocks[_blockNumber].priorityOperations,
            blocks[_blockNumber].validator
        );

        totalBlocksVerified += 1;

        emit BlockVerified(_blockNumber);
    }

    /// @notice When block with withdrawals is verified we store them and complete in separate tx. Withdrawals can be complete by calling withdrawEth, withdrawERC20 or completeWithdrawals.
    /// @param _to Reciever
    /// @param _tokenId Token id
    /// @param _amount Token amount
    function storeWithdrawalAsPending(address _to, uint16 _tokenId, uint128 _amount) internal {
        pendingWithdrawals[firstPendingWithdrawalIndex + numberOfPendingWithdrawals] = PendingWithdrawal(_to, _tokenId);
        numberOfPendingWithdrawals++;

        balancesToWithdraw[_to][_tokenId] += _amount;
    }

    /// @notice If block is verified the onchain operations from it must be completed
    /// @notice (user must have possibility to withdraw funds if withdrawed)
    /// @param _blockNumber Number of block
    function consummateOnchainOps(uint32 _blockNumber) internal {
        uint64 start = blocks[_blockNumber].operationStartId;
        uint64 end = start + blocks[_blockNumber].onchainOperations;
        for (uint64 current = start; current < end; ++current) {
            OnchainOperation memory op = onchainOps[current];
            if (op.opType == Operations.OpType.PartialExit) {
                // partial exit was successful, accrue balance
                Operations.PartialExit memory data = Operations.readPartialExitPubdata(op.pubData, 0);
                storeWithdrawalAsPending(data.owner, data.tokenId, data.amount);
            }
            if (op.opType == Operations.OpType.FullExit) {
                // full exit was successful, accrue balance
                Operations.FullExit memory data = Operations.readFullExitPubdata(op.pubData, 0);
                storeWithdrawalAsPending(data.owner, data.tokenId, data.amount);
            }
            delete onchainOps[current];
        }
    }

    /// @notice Checks that commitment is expired and revert blocks if it really is
    /// @return bool flag that indicates if blocks has been reverted
    function triggerRevertIfBlockCommitmentExpired() internal returns (bool) {
        if (
            totalBlocksCommitted > totalBlocksVerified &&
            blocks[totalBlocksVerified + 1].committedAtBlock > 0 &&
            block.number > blocks[totalBlocksVerified + 1].committedAtBlock + EXPECT_VERIFICATION_IN
        ) {
            revertBlocks();
            return true;
        }
        return false;
    }

    /// @notice Reverts unverified blocks
    function revertBlocks() internal {
        for (uint32 i = totalBlocksVerified + 1; i <= totalBlocksCommitted; i++) {
            Block memory reverted = blocks[i];
            revertBlock(reverted);
            delete blocks[i];
        }
        totalBlocksCommitted -= totalBlocksCommitted - totalBlocksVerified;
        emit BlocksReverted(totalBlocksVerified, totalBlocksCommitted);
    }

    /// @notice Reverts block onchain operations
    /// @param _reverted Reverted block
    function revertBlock(Block memory _reverted) internal {
        require(_reverted.committedAtBlock > 0, "frk11"); // block not found
        revertOnchainOps(_reverted.operationStartId, _reverted.onchainOperations);
        priorityQueue.decreaseCommittedRequestsNumber(_reverted.priorityOperations);
    }

    /// @notice Checks that current state not is exodus mode
    function requireActive() internal view {
        require(!exodusMode, "fre11"); // exodus mode activated
    }

    /// @notice Checks if Exodus mode must be entered. If true - cancels outstanding deposits and emits ExodusMode event.
    /// @dev Exodus mode must be entered in case of current ethereum block number is higher than the oldest
    /// @dev of existed priority requests expiration block number.
    /// @return bool flag that is true if the Exodus mode must be entered.
    function triggerExodusIfNeeded() internal returns (bool) {
        if (priorityQueue.triggerExodusIfNeeded()) {
            exodusMode = true;
            emit ExodusMode();
            return true;
        } else {
            return false;
        }
    }

    /// @notice Withdraws token from Franklin to root chain in case of exodus mode. User must provide proof that he owns funds
    /// @param _proof Proof
    /// @param _tokenId Verified token id
    /// @param _owner Owner
    /// @param _amount Amount for owner
    function exit(
        uint16 _tokenId,
        address _owner,
        uint128 _amount,
        uint256[8] calldata _proof
    ) external {
        require(exodusMode, "fet11"); // must be in exodus mode
        require(exited[_owner][_tokenId] == false, "fet12"); // already exited
        require(verifier.verifyExitProof(_tokenId, _owner, _amount, _proof), "fet13"); // verification failed

        balancesToWithdraw[_owner][_tokenId] += _amount;
        exited[_owner][_tokenId] == false;
    }

    function authPubkeyHash(bytes calldata _fact, uint32 _nonce) external {
        require(_fact.length == PUBKEY_HASH_BYTES, "ahf10"); // PubKeyHash should be 20 bytes.
        require(authFacts[msg.sender][_nonce].length == 0, "ahf11"); // auth fact for nonce should be empty

        authFacts[msg.sender][_nonce] = _fact;

        emit FactAuth(msg.sender, _nonce, _fact);
    }
}
