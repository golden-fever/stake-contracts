/*
 * Copyright (c)
 */

pragma solidity 0.5.3;

import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";
import "./utils/ArraySet.sol";
import "./utils/Permissionable.sol";

contract Lottery is Permissionable {
  using ArraySet for ArraySet.Uint256Set;

  string public constant FEE_MANAGER_ROLE = "fee_manager";
  string public constant ACTIVE_MANAGER_ROLE = "active_manager";
  string public constant CONFIG_MANAGER_ROLE = "config_manager";

  enum CurrencyType {
    ETH,
    ERC20
  }

  bool public active;
  uint public roundDuration;
  uint public memberSubtractRoundMultiplier;
  uint public startTimestamp;
  uint public lastRoundIncrementTimestamp;
  uint public currentRoundNumber;

  CurrencyType public currencyType;
  address public currencyAddress;
  uint public initialTicketPrice;
  uint public lastWinnersCount;

  uint constant feePrecision = 1 ether;
  address feeBank;
  uint feeForWithdraw;
  
  uint public feePercent;

  struct LotteryRound {
    uint duration;
    uint startedAt;
    uint ticketPrice;

    address[] membersTickets;
    // member numbers by address
    mapping(address => uint[]) ticketsOfMember;

    // ticket number => paid sum
    mapping(uint => uint) ticketPaid;
    // ticket number => wins amount
    mapping(uint => uint) wonAmount;
    // ticket number => amount already withdrawal
    mapping(uint => uint) withdrawalAmount;
    // ticket number => distributed for previous count
    mapping(uint => uint) forPreviousDistributed;

    uint totalPaid;
    uint totalFee;
    uint distributedForLastWinners;
  }

  // roundNumber => Round  
  mapping(uint => LotteryRound) internal rounds;

  // tickets count => ticket price
  mapping(uint => uint) internal newPriceOnTicketsCount;
  ArraySet.Uint256Set ticketsCountsWithNewPrice;

  constructor(CurrencyType _currencyType, address _currencyAddress, uint _roundDuration, uint _initialPayment, uint _lastWinnersCount, uint _memberSubtractRoundMultiplier) public {
    currencyType = _currencyType;
    currencyAddress = _currencyAddress;

    roundDuration = _roundDuration;
    initialTicketPrice = _initialPayment;
    lastWinnersCount = _lastWinnersCount;
    memberSubtractRoundMultiplier = _memberSubtractRoundMultiplier;

    addRoleTo(msg.sender, FEE_MANAGER_ROLE);
    addRoleTo(msg.sender, ACTIVE_MANAGER_ROLE);
    addRoleTo(msg.sender, CONFIG_MANAGER_ROLE);
  }

  function() external payable {
    buyTicket();
  }

  modifier onlyFeeManager() {
    require(hasRole(msg.sender, FEE_MANAGER_ROLE), "Only fee manager");
    _;
  }

  modifier onlyActiveManager() {
    require(hasRole(msg.sender, ACTIVE_MANAGER_ROLE), "Only active manager");
    _;
  }

  modifier onlyConfigManager() {
    require(hasRole(msg.sender, CONFIG_MANAGER_ROLE), "Only config manager");
    _;
  }

  function setFee(uint _feePercent, address _feeBank) public onlyFeeManager {
    feePercent = _feePercent;
    feeBank = _feeBank;
  }
  
  function withdrawFee(uint _feeAmount) public onlyFeeManager {
    require(_feeAmount <= feeForWithdraw, "Not enough fee earned for withdraw");

    sendAmountToUnsafe(_feeAmount, feeBank);
    feeForWithdraw -= _feeAmount;
  }

  function configure(uint _roundDuration, uint _initialTicketPrice, uint _lastWinnersCount, uint _memberSubtractRoundMultiplier) public onlyConfigManager {
    roundDuration = _roundDuration;
    initialTicketPrice = _initialTicketPrice;
    lastWinnersCount = _lastWinnersCount;
    memberSubtractRoundMultiplier = _memberSubtractRoundMultiplier;
  }
  
  function setNewPriceOnTicketsCount(uint _newPrice, uint ticketsCount) public onlyConfigManager {
    newPriceOnTicketsCount[ticketsCount] = _newPrice;
    if (_newPrice > 0) {
      ticketsCountsWithNewPrice.addSilent(ticketsCount);
    } else {
      ticketsCountsWithNewPrice.removeSilent(ticketsCount);
    }
  }

  function start() public onlyActiveManager {
    require(!active, "Already active");
    active = true;
    if (startTimestamp == 0) {
      startTimestamp = block.timestamp;
      lastRoundIncrementTimestamp = startTimestamp;
      rounds[0].ticketPrice = initialTicketPrice;
      rounds[0].duration = roundDuration;
      rounds[0].startedAt = block.timestamp;
    }
  }

  function stop() public onlyActiveManager {
    require(active, "Already inactive");
    active = false;
  }

  function checkRoundEnd() public {
    if (block.timestamp - lastRoundIncrementTimestamp >= rounds[currentRoundNumber].duration) {
      currentRoundNumber += 1;
      lastRoundIncrementTimestamp = block.timestamp;
      rounds[currentRoundNumber].ticketPrice = initialTicketPrice;
      rounds[currentRoundNumber].duration = roundDuration;
      rounds[currentRoundNumber].startedAt = block.timestamp;
    }
  }

  event LogNumber(string s, uint n);
  
  function buyTicket() public payable {
    require(active, "Not active");

    checkRoundEnd();

    LotteryRound storage _round = rounds[currentRoundNumber];

    _round.membersTickets.push(msg.sender);
    _round.duration = _round.duration - getUntilCurrentRoundEnd() + roundDuration - memberSubtractRoundMultiplier * _round.membersTickets.length;
    
    uint _ticketNumber = _round.membersTickets.length - 1;
    _round.ticketsOfMember[msg.sender].push(_ticketNumber);

    if (newPriceOnTicketsCount[_round.membersTickets.length] > 0) {
      _round.ticketPrice = newPriceOnTicketsCount[_round.membersTickets.length];
    }

    if (currencyType == CurrencyType.ETH) {
      require(msg.value == _round.ticketPrice, "Not valid value");
    } else {
      ERC20(currencyAddress).transferFrom(msg.sender, address(this), _round.ticketPrice);
    }

    uint _feeAmount;
    if (feePercent > 0) {
      _feeAmount = (_round.ticketPrice * feePrecision) / feePercent;
    }
    _round.ticketPaid[_ticketNumber] = _round.ticketPrice - _feeAmount;
    _round.totalPaid += _round.ticketPaid[_ticketNumber];
    _round.totalFee += _feeAmount;
    feeForWithdraw += _feeAmount;
  }

  function distributeForPrevious(uint _roundNumber, uint _ticketNumber, uint _distributeForCount) public {
    require(_ticketNumber != 0 && _distributeForCount != 0, "ticketNumber and distributeForCount can't be equal 0");
    LotteryRound storage _round = rounds[_roundNumber];
    require(_round.ticketPaid[_ticketNumber] != 0, "There is no payment for this member");
    require(_round.forPreviousDistributed[_ticketNumber] != _ticketNumber, "Member already distributed for previous");

    uint i = _round.forPreviousDistributed[_ticketNumber];

    uint _amountPerMember = (_round.ticketPaid[_ticketNumber] / 2) / _ticketNumber;
    while (i < _distributeForCount) {
      _round.wonAmount[i] += _amountPerMember;
      i++;
      if (i == _ticketNumber) {
        break;
      }
    }

    _round.forPreviousDistributed[_ticketNumber] = i;
  }

  function distributeForLastWinners(uint _roundNumber) public {
    require(_roundNumber < currentRoundNumber, "roundNumber should be less then currentRoundNumber");
    LotteryRound storage _round = rounds[_roundNumber];
    require(_round.distributedForLastWinners == 0, "already distributed for last winners");

    uint _amountPerMember = (_round.totalPaid / 2) / lastWinnersCount;

    for (uint256 i; i < lastWinnersCount; i++) {
      uint _winnerMemberNumber = _round.membersTickets.length - i;
      _round.wonAmount[_winnerMemberNumber] += _amountPerMember;
    }

    _round.distributedForLastWinners = lastWinnersCount;
  }

  function claimWin(uint _roundNumber, uint _ticketNumber) public {
    require(_roundNumber < currentRoundNumber, "roundNumber should be less then currentRoundNumber");
    LotteryRound storage _round = rounds[_roundNumber];
    require(_round.membersTickets[_ticketNumber] == msg.sender, "ticketNumber should point to msg.sender");
    require(_round.withdrawalAmount[_ticketNumber] != _round.wonAmount[_ticketNumber], "All wins are already withdrawal");

    sendAmountToUnsafe(_round.wonAmount[_ticketNumber] - _round.withdrawalAmount[_ticketNumber], msg.sender);
    
    _round.withdrawalAmount[_ticketNumber] = _round.wonAmount[_ticketNumber];
  }

  function claimAllTicketsWin(uint _roundNumber) public {
    require(_roundNumber < currentRoundNumber, "roundNumber should be less then currentRoundNumber");
    LotteryRound storage _round = rounds[_roundNumber];

    uint _winForTransfer;
    for (uint256 i = 0; i < _round.ticketsOfMember[msg.sender].length; i++) {
      uint _ticketNumber = _round.ticketsOfMember[msg.sender][i];
      _winForTransfer += (_round.wonAmount[_ticketNumber] - _round.withdrawalAmount[_ticketNumber]);
      _round.withdrawalAmount[_ticketNumber] = _round.wonAmount[_ticketNumber];
    }
    
    require(_winForTransfer != 0, "All wins are already withdrawal");

    sendAmountToUnsafe(_winForTransfer, msg.sender);
  }
  
  function sendAmountToUnsafe(uint _amount, address _to) private {
    if (currencyType == CurrencyType.ETH) {
      msg.sender.transfer(_amount);
    } else {
      ERC20(currencyAddress).transferFrom(address(this), _to, _amount);
    }
  }
  
  // Getters

  function getUntilCurrentRoundEnd() public view returns (uint) {
    return lastRoundIncrementTimestamp + rounds[currentRoundNumber].duration - block.timestamp;
  }
  
  function getLotteryInfo() view external returns (
    bool _active,
    uint _roundDuration,
    uint _memberSubtractRoundMultiplier,
    uint _startTimestamp,
    uint _lastRoundIncrementTimestamp,
    uint _currentRoundNumber,
    CurrencyType _currencyType,
    address _currencyAddress,
    uint _initialTicketPrice,
    uint _lastWinnersCount,
    uint _feePercent
  ) {
    return (
      active,
      roundDuration,
      memberSubtractRoundMultiplier,
      startTimestamp,
      lastRoundIncrementTimestamp,
      currentRoundNumber,
      currencyType,
      currencyAddress,
      initialTicketPrice,
      lastWinnersCount,
      feePercent
    );
  }

  function getFeeInfo() view external onlyFeeManager returns (
    address _feeBank,
    uint _feePrecision,
    uint _feeForWithdraw
  ) {
    return (
      feeBank,
      feePrecision,
      feeForWithdraw
    );
  }

  function getRoundInfo(uint _roundNumber) view external returns (
    uint duration,
    uint startedAt,
    uint ticketsCount,
    uint totalPaid,
    uint totalFee,
    uint ticketPrice,
    uint distributedForLastWinners
  ) {
    LotteryRound storage _round = rounds[_roundNumber];
    return (
      _round.duration,
      _round.startedAt,
      _round.membersTickets.length,
      _round.totalPaid,
      _round.totalFee,
      _round.ticketPrice,
      _round.distributedForLastWinners
    );
  }

  function getRoundLastWinnersTickets(uint _roundNumber) view external returns (uint[] memory) {
    LotteryRound storage _round = rounds[_roundNumber];
    
    uint[] memory _list = new uint[](_round.distributedForLastWinners);
    uint _ticketsCount = _round.membersTickets.length;
    for(uint i = 0; i < _round.distributedForLastWinners; i++) {
      _list[i] = _ticketsCount - _round.distributedForLastWinners + i + 1;
    }
    return _list;
  }

  function getTicketRoundInfo(uint _roundNumber, uint _ticketNumber) view external returns (
    uint forPreviousDistributedCount,
    uint paidAmount,
    uint wonAmount,
    uint withdrawalAmount
  ) {
    LotteryRound storage _round = rounds[_roundNumber];
    return (
      _round.forPreviousDistributed[_ticketNumber],
      _round.ticketPaid[_ticketNumber],
      _round.wonAmount[_ticketNumber],
      _round.withdrawalAmount[_ticketNumber]
    );
  }
  
  function getMemberRoundInfo(uint _roundNumber, address _member) view external returns (
    uint ticketsCount,
    uint paidSum,
    uint wonSum
  ) {
    LotteryRound storage _round = rounds[_roundNumber];
    uint _paidSum = 0;
    uint _wonSum = 0;
    for (uint256 i = 0; i < _round.ticketsOfMember[_member].length; i++) {
      _paidSum += _round.ticketPaid[_round.ticketsOfMember[_member][i]];
      _wonSum += _round.wonAmount[_round.ticketsOfMember[_member][i]];
    }
    return (
      _round.ticketsOfMember[_member].length,
      // paid sum without fee
      _paidSum,
      _wonSum
    );
  }

  function getMemberAfterRoundInfo(uint _roundNumber, address _member) view external returns (
    uint ticketsCount,
    uint notDistributedForPreviousCount,
    uint withdrawalSum
  ) {
    LotteryRound storage _round = rounds[_roundNumber];
    for (uint256 i = 0; i < _round.ticketsOfMember[_member].length; i++) {
      notDistributedForPreviousCount += (_round.ticketsOfMember[_member][i] - _round.forPreviousDistributed[_round.ticketsOfMember[_member][i]]);
      withdrawalSum += _round.withdrawalAmount[_round.ticketsOfMember[_member][i]];
    }
    return (
      _round.ticketsOfMember[_member].length,
      notDistributedForPreviousCount,
      withdrawalSum
    );
  }

  function getMemberRoundTickets(uint _roundNumber, address _member) view external returns (
    uint[] memory tickets,
    uint[] memory paid,
    uint[] memory wins
  ) {
    LotteryRound storage _round = rounds[_roundNumber];
    paid = new uint256[](_round.ticketsOfMember[_member].length);
    wins = new uint256[](_round.ticketsOfMember[_member].length);
    
    for (uint256 i = 0; i < _round.ticketsOfMember[_member].length; i++) {
      paid[i] = _round.ticketPaid[_round.ticketsOfMember[_member][i]];
      wins[i] = _round.wonAmount[_round.ticketsOfMember[_member][i]];
    }
    return (
      _round.ticketsOfMember[_member],
      // paid array without fee
      paid,
      wins
    );
  }

  function getRoundTicketInfo(uint _roundNumber, uint _ticketNumber) view external returns (
    address member,
    uint wonAmount,
    uint withdrawalAmount,
    uint paidAmount,
    uint forPreviousDistributed
  ) {
    LotteryRound storage _round = rounds[_roundNumber];
    return (
      _round.membersTickets[_ticketNumber],
      _round.wonAmount[_ticketNumber],
      _round.withdrawalAmount[_ticketNumber],
      _round.ticketPaid[_ticketNumber],
      _round.forPreviousDistributed[_ticketNumber]
    );
  }
  
  function getNewPriceOnTicketNumbersInfo() view external returns (
    uint[] memory ticketsNumbers,
    uint[] memory newTicketsPrices
  ) {
    ticketsNumbers = ticketsCountsWithNewPrice.elements();
    uint _length = ticketsCountsWithNewPrice.size();
    
    newTicketsPrices = new uint256[](_length);
    for (uint256 i = 0; i < _length; i++) {
      newTicketsPrices[i] = newPriceOnTicketsCount[ticketsNumbers[i]];
    }
  }
}
