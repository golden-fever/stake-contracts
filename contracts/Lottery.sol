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
    uint initialTicketPrice;
    uint ticketPrice;

    address[] membersTickets;
    // member numbers by address
    mapping(address => uint[]) ticketsOfMember;
    
    mapping(uint => LotteryTicket) ticket;

    uint totalPaid;
    uint totalFee;
    uint lastWinnersCount;
    uint distributedForLastWinners;
  
    mapping(uint => uint) newPriceOnTicketsCount;
    uint[] ticketsCountsWithNewPrice;
  }

  struct LotteryTicket {
    uint paidAt;
    uint paidAmount;
    uint wonAmount;
    uint withdrawalAmount;
    
    uint byNextDistributed;
    uint nextDistributePrice;
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
  
  function initRoundUnsafe() private {
    lastRoundIncrementTimestamp = block.timestamp;
    rounds[currentRoundNumber].initialTicketPrice = initialTicketPrice;
    rounds[currentRoundNumber].ticketPrice = initialTicketPrice;
    rounds[currentRoundNumber].duration = roundDuration;
    rounds[currentRoundNumber].startedAt = block.timestamp;
    rounds[currentRoundNumber].lastWinnersCount = lastWinnersCount;

    rounds[currentRoundNumber].ticketsCountsWithNewPrice = ticketsCountsWithNewPrice.elements();
    uint _length = ticketsCountsWithNewPrice.size();

    for (uint256 i = 0; i < _length; i++) {
      uint ticketsCount = rounds[currentRoundNumber].ticketsCountsWithNewPrice[i];
      rounds[currentRoundNumber].newPriceOnTicketsCount[ticketsCount] = newPriceOnTicketsCount[ticketsCount];
    }
  }

  function start() public onlyActiveManager {
    require(!active, "Already active");
    active = true;
    if (startTimestamp == 0) {
      startTimestamp = block.timestamp;
      initRoundUnsafe();
    }
  }

  function stop() public onlyActiveManager {
    require(active, "Already inactive");
    active = false;
  }

  function checkRoundEnd() public {
    if (block.timestamp - lastRoundIncrementTimestamp >= rounds[currentRoundNumber].duration) {
      currentRoundNumber += 1;
      initRoundUnsafe();
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
    _round.ticket[_ticketNumber].paidAt = block.timestamp;
    _round.ticket[_ticketNumber].paidAmount = _round.ticketPrice - _feeAmount;
    _round.totalPaid += _round.ticket[_ticketNumber].paidAmount;
    _round.totalFee += _feeAmount;
    feeForWithdraw += _feeAmount;
  }

  function distributeByNext(uint _roundNumber, uint _ticketNumber, uint _distributeForCount) public {
    require(_distributeForCount != 0, "distributeForCount can't be equal 0");
    LotteryRound storage _round = rounds[_roundNumber];
    require(_round.ticket[_ticketNumber].paidAmount != 0, "There is no payment for this member");
    
    if(_round.ticket[_ticketNumber].nextDistributePrice == 0) {
      uint _length = _round.ticketsCountsWithNewPrice.length;

      uint newPrice = _round.initialTicketPrice;
      for (uint256 i = 0; i < _length; i++) {
        if(_ticketNumber >= _round.ticketsCountsWithNewPrice[i]) {
          newPrice = _round.newPriceOnTicketsCount[_round.ticketsCountsWithNewPrice[i]];
        }
      }
      _round.ticket[_ticketNumber].nextDistributePrice = newPrice;
    }
    
    if(_round.ticket[_ticketNumber].byNextDistributed == 0) {
      _round.ticket[_ticketNumber].byNextDistributed = _ticketNumber;
    }
    
    uint i = _round.ticket[_ticketNumber].byNextDistributed;
    require(i < _round.membersTickets.length, "End of round members reached");
    require(i + _distributeForCount < _round.membersTickets.length, "Too much distributeForCount");

    uint addWon = 0;
    uint addWonDivider = 0;
    while (i < _round.ticket[_ticketNumber].byNextDistributed + _distributeForCount) {
      i++;
      
      if (_round.newPriceOnTicketsCount[i] != 0) {
        addWon += (addWonDivider * _round.ticket[_ticketNumber].nextDistributePrice) / 1 ether;
        _round.ticket[_ticketNumber].nextDistributePrice = _round.newPriceOnTicketsCount[i];
        addWonDivider = 0;
      }
      addWonDivider += 1 ether / (i * 2);
    }
    
    _round.ticket[_ticketNumber].wonAmount += addWon + ((addWonDivider * _round.ticket[_ticketNumber].nextDistributePrice) / 1 ether);
    _round.ticket[_ticketNumber].byNextDistributed = i;
  }

  event LastWinnerDistribute(uint roundNumber, uint ticketNumber, uint amount);
  
  function distributeForLastWinners(uint _roundNumber) public {
    require(_roundNumber < currentRoundNumber, "roundNumber should be less then currentRoundNumber");
    LotteryRound storage _round = rounds[_roundNumber];
    require(_round.distributedForLastWinners == 0, "already distributed for last winners");

    uint _actualWinnersCount = _round.lastWinnersCount > _round.membersTickets.length ? _round.membersTickets.length : _round.lastWinnersCount;
    uint _amountPerMember = _round.totalPaid / (2 * _actualWinnersCount);

    for (uint256 i; i < _actualWinnersCount; i++) {
      uint _winnerTicketNumber = _round.membersTickets.length - i;
      _round.ticket[_winnerTicketNumber].wonAmount += _amountPerMember;
      emit LastWinnerDistribute(_roundNumber, _winnerTicketNumber, _amountPerMember);
    }

    _round.distributedForLastWinners = _actualWinnersCount;
  }

  function claimWin(uint _roundNumber, uint _ticketNumber) public {
    require(_roundNumber < currentRoundNumber, "roundNumber should be less then currentRoundNumber");
    LotteryRound storage _round = rounds[_roundNumber];
    require(_round.membersTickets[_ticketNumber] == msg.sender, "ticketNumber should point to msg.sender");
    require(_round.ticket[_ticketNumber].withdrawalAmount != _round.ticket[_ticketNumber].wonAmount, "All wins are already withdrawal");

    sendAmountToUnsafe(_round.ticket[_ticketNumber].wonAmount - _round.ticket[_ticketNumber].withdrawalAmount, msg.sender);

    _round.ticket[_ticketNumber].withdrawalAmount = _round.ticket[_ticketNumber].wonAmount;
  }

  function claimAllTicketsWin(uint _roundNumber) public {
    require(_roundNumber < currentRoundNumber, "roundNumber should be less then currentRoundNumber");
    LotteryRound storage _round = rounds[_roundNumber];

    uint _winForTransfer;
    for (uint256 i = 0; i < _round.ticketsOfMember[msg.sender].length; i++) {
      uint _ticketNumber = _round.ticketsOfMember[msg.sender][i];
      _winForTransfer += (_round.ticket[_ticketNumber].wonAmount - _round.ticket[_ticketNumber].withdrawalAmount);
      _round.ticket[_ticketNumber].withdrawalAmount = _round.ticket[_ticketNumber].wonAmount;
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
    uint initialTicketPrice,
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
      _round.initialTicketPrice,
      _round.ticketPrice,
      _round.distributedForLastWinners
    );
  }

  function getRoundLastWinnersTickets(uint _roundNumber) view external returns (uint[] memory) {
    LotteryRound storage _round = rounds[_roundNumber];

    uint _ticketsCount = _round.membersTickets.length;
    uint _actualWinnersCount = _round.lastWinnersCount > _ticketsCount ? _ticketsCount : _round.lastWinnersCount;
    uint[] memory _list = new uint[](_actualWinnersCount);
    for (uint i = 0; i < _actualWinnersCount; i++) {
      _list[i] = _ticketsCount - _actualWinnersCount + i + 1;
    }
    return _list;
  }

  function getTicketRoundInfo(uint _roundNumber, uint _ticketNumber) view external returns (
    address member,
    uint byNextDistributed,
    uint paidAt,
    uint paidAmount,
    uint wonAmount,
    uint withdrawalAmount
  ) {
    LotteryTicket storage _ticket = rounds[_roundNumber].ticket[_ticketNumber];
    return (
      rounds[_roundNumber].membersTickets[_ticketNumber],
      _ticket.byNextDistributed,
      _ticket.paidAt,
      _ticket.paidAmount,
      _ticket.wonAmount,
      _ticket.withdrawalAmount
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
      _paidSum += _round.ticket[_round.ticketsOfMember[_member][i]].paidAmount;
      _wonSum += _round.ticket[_round.ticketsOfMember[_member][i]].wonAmount;
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
    uint notDistributedByNext,
    uint withdrawalSum
  ) {
    LotteryRound storage _round = rounds[_roundNumber];
    for (uint256 i = 0; i < _round.ticketsOfMember[_member].length; i++) {
      uint _distributed = _round.ticket[_round.ticketsOfMember[_member][i]].byNextDistributed;
      if(_distributed == 0) {
        _distributed = _round.ticketsOfMember[_member][i];
      }
      notDistributedByNext += _round.membersTickets.length - 1 - _distributed;
      withdrawalSum += _round.ticket[_round.ticketsOfMember[_member][i]].withdrawalAmount;
    }
    return (
      _round.ticketsOfMember[_member].length,
      notDistributedByNext,
      withdrawalSum
    );
  }

  function getMemberRoundTickets(uint _roundNumber, address _member) view external returns (uint[] memory) {
    return rounds[_roundNumber].ticketsOfMember[_member];
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

  function getRoundNewPriceOnTicketNumbersInfo(uint _roundNumber) view external returns (
    uint[] memory ticketsNumbers,
    uint[] memory newTicketsPrices
  ) {
    LotteryRound storage _round = rounds[_roundNumber];
    ticketsNumbers = _round.ticketsCountsWithNewPrice;
    uint _length = _round.ticketsCountsWithNewPrice.length;

    newTicketsPrices = new uint256[](_length);
    for (uint256 i = 0; i < _length; i++) {
      newTicketsPrices[i] = _round.newPriceOnTicketsCount[ticketsNumbers[i]];
    }
  }
}
