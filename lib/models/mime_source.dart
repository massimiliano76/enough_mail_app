import 'package:enough_mail/enough_mail.dart';
import 'dart:async';

import 'package:enough_mail_app/services/notification_service.dart';

import '../locator.dart';

abstract class MimeSourceSubscriber {
  void onMailLoaded(MimeMessage mime, MimeSource source);
  void onMailAdded(MimeMessage mime, MimeSource source);
  void onMailVanished(MimeMessage mime, MimeSource source);
  void onMailFlagsUpdated(MimeMessage mime, MimeSource source);
}

abstract class MimeSource {
  final MailClient mailClient;
  int get size;
  final _subscribers = <MimeSourceSubscriber>[];
  StreamSubscription<MailLoadEvent> _mailLoadEventSubscription;
  StreamSubscription<MailVanishedEvent> _mailVanishedEventSubscription;
  StreamSubscription<MailUpdateEvent> _mailUpdatedEventSubscription;
  Future _downloadFuture;
  Future get downloadFuture => _downloadFuture;

  String get name;

  bool get suppportsDeleteAll;

  bool get isSequenceIdBased;

  MimeSource search(MailSearch search);

  bool get supportsMessageFolders => (mailClient.mailboxes?.length != 0);
  bool get shouldBlockImages => isJunk || isTrash;

  bool get isJunk;
  bool get isTrash;

  bool get isArchive;

  Future<List<DeleteResult>> deleteAllMessages();

  bool get supportsSearching;

  MimeSource(this.mailClient, {MimeSourceSubscriber subscriber}) {
    if (subscriber != null) {
      _subscribers.add(subscriber);
    }
    _registerEvents();
  }

  Future<bool> init();

  void remove(MimeMessage mimeMessage);

  void dispose() {
    _deregisterEvents();
  }

  void addSubscriber(MimeSourceSubscriber subscriber) {
    _subscribers.add(subscriber);
  }

  void removeSubscriber(MimeSourceSubscriber subscriber) {
    _subscribers.remove(subscriber);
  }

  MimeMessage getMessageAt(int index);

  void addMessage(MimeMessage message);

  void _registerEvents() {
    _mailLoadEventSubscription =
        mailClient.eventBus.on<MailLoadEvent>().listen(_onMessageAdded);
    _mailVanishedEventSubscription =
        mailClient.eventBus.on<MailVanishedEvent>().listen(_onMessageVanished);
    _mailUpdatedEventSubscription =
        mailClient.eventBus.on<MailUpdateEvent>().listen(_onMailFlagsUpdated);
  }

  void _deregisterEvents() {
    _mailLoadEventSubscription.cancel();
    _mailVanishedEventSubscription.cancel();
    _mailUpdatedEventSubscription.cancel();
  }

  void _onMessageAdded(MailLoadEvent e) {
    print('${DateTime.now()}: ${e.message.decodeSubject()}');
    if (e.mailClient == mailClient) {
      if (matches(e.message)) {
        addMessage(e.message);
        _notifyMessageAdded(e.message);
      } else {
        locator<NotificationService>().sendLocalNotificationForMailLoadEvent(e);
      }
    }
    // else {
    //   locator<ScaffoldService>().showTextSnackBar(e.message.decodeSubject());
    // }
  }

  /// Checks if the specified new [messages] matches this mime source.
  /// The default implementation always returns true.
  bool matches(MimeMessage message) {
    return true;
  }

  void _notifyMessageAdded(MimeMessage mime) {
    for (final subscriber in _subscribers) {
      subscriber.onMailAdded(mime, this);
    }
  }

  void removeVanishedMessages(MessageSequence sequence);

  void _onMessageVanished(MailVanishedEvent e) {
    if (!e.isEarlier && e.mailClient == mailClient) {
      removeVanishedMessages(e.sequence);
    }
  }

  void _notifyVanished(MimeMessage mime) {
    for (final subscriber in _subscribers) {
      subscriber.onMailVanished(mime, this);
    }
  }

  void _onMailFlagsUpdated(MailUpdateEvent e) {
    if (e.mailClient == mailClient) {
      _notifyFlagsUpdated(e.message);
      // //final uid = e.message.uid;
      // final sequenceId = e.message.sequenceId;
      // var message = _getMessageFromCache(sequenceId);
      // // uid != null
      // //     ? messages.firstWhere((m) => m.mimeMessage.uid == uid,
      // //         orElse: () => null)
      // //     : messages.firstWhere((m) => m.mimeMessage.sequenceId == sequenceId,
      // //         orElse: () => null);
      // // print(
      // //     'message updated: uid=$uid, id=$sequenceId, flags=${e.message.flags}. Found existing message: $message');
      // if (message != null) {
      //   _notifyFlagsUpdated(message);
      // }
    }
  }

  void _notifyFlagsUpdated(MimeMessage mime) {
    for (final subscriber in _subscribers) {
      subscriber.onMailFlagsUpdated(mime, this);
    }
  }

  void _notifyLoaded(MimeMessage mime) {
    for (final subscriber in _subscribers) {
      subscriber.onMailLoaded(mime, this);
    }
  }
}

class MailboxMimeSource extends MimeSource {
  Mailbox mailbox;
  final _requestedPages = <int>[];
  final List<MimeMessage> _cache = <MimeMessage>[];
  final int pageSize;
  final int cacheSize;

  @override
  int get size => mailbox.messagesExists;

  @override
  String get name => mailbox.name;

  @override
  bool get suppportsDeleteAll => (mailbox.isTrash || mailbox.isJunk);

  @override
  bool get isJunk => mailbox.isJunk;

  @override
  bool get isTrash => mailbox.isTrash;

  @override
  bool get isArchive => mailbox.isArchive;

  @override
  bool get supportsSearching => true;

  MailboxMimeSource(MailClient mailClient, this.mailbox,
      {this.pageSize = 20,
      this.cacheSize = 100,
      MimeSourceSubscriber subscriber})
      : super(mailClient, subscriber: subscriber);

  @override
  Future<bool> init() async {
    if (mailbox == null) {
      mailbox = await mailClient.selectInbox();
    } else {
      mailbox = await mailClient.selectMailbox(mailbox);
    }
    // pre-cache first page:
    await _download(0);
    return true;
  }

  @override
  void addMessage(MimeMessage message) {
    _cache.add(message);
  }

  @override
  void removeVanishedMessages(MessageSequence sequence) {
    final ids = sequence.toList();
    MimeMessage message;
    int sequenceId;
    for (var id in ids) {
      if (sequence.isUidSequence == true) {
        message = _getMessageFromCacheWithUid(id);
        sequenceId = message?.sequenceId;
      } else {
        sequenceId = id;
        message = _getMessageFromCache(id);
      }
      if (message != null) {
        _cache.remove(message);
      }
      if (sequenceId != null) {
        for (var message in _cache) {
          if (message.sequenceId >= sequenceId) {
            message.sequenceId--;
          }
        }
      }
      if (message != null) {
        _notifyVanished(message);
      }
    }
  }

  @override
  Future<List<DeleteResult>> deleteAllMessages() async {
    final deleteResult = await mailClient.deleteAllMessages(mailbox);
    mailbox.messagesExists = 0;
    return [deleteResult];
  }

  @override
  void remove(MimeMessage mimeMessage) {
    mailbox.messagesExists--;
    _cache.remove(mimeMessage);
  }

  @override
  MimeSource search(MailSearch search) {
    return SearchMimeSource(mailClient, search, mailbox);
  }

  @override
  MimeMessage getMessageAt(int index) {
    //print('getMessageAt($index)');
    if (index >= size) {
      throw StateError('Invalid index $index for MimeSource with size $size');
    }
    final sequenceId = (size - index);
    final existingMessage = _getMessageFromCache(sequenceId);
    if (existingMessage != null) {
      return existingMessage;
    }
    final pageIndex = index ~/ pageSize;
    if (!_requestedPages.contains(pageIndex)) {
      _queue(pageIndex);
    }
    print('getMessageAt($index) yields ID $sequenceId');
    return MimeMessage()..sequenceId = sequenceId;
  }

  MimeMessage _getMessageFromCache(int sequenceId) {
    return _cache.firstWhere((m) => m.sequenceId == sequenceId,
        orElse: () => null);
  }

  MimeMessage _getMessageFromCacheWithUid(int uid) {
    return _cache.firstWhere((m) => m.uid == uid, orElse: () => null);
  }

  void _queue(int pageIndex) {
    //print('queuing $pageIndex');
    _requestedPages.insert(0, pageIndex);
    if (_requestedPages.length > 5) {
      // just skip the olded referenced messages
      _requestedPages.removeLast();
    }
    if (_requestedPages.length == 1) {
      _downloadFuture = _download(pageIndex);
    }
  }

  Future<void> _download(int pageIndex) async {
    //print('downloading $pageIndex');
    await mailClient.stopPollingIfNeeded();
    final mimeMessages = await mailClient.fetchMessages(
        count: pageSize,
        page: (pageIndex + 1),
        fetchPreference: FetchPreference.envelope);
    _requestedPages.remove(pageIndex);
    for (final mime in mimeMessages) {
      final cached = _getMessageFromCache(mime.sequenceId);
      if (cached == null) {
        _cache.add(mime);
      }
      _notifyLoaded(mime);
    }
    if (_cache.length > cacheSize) {
      _cache.removeRange(0, _cache.length - cacheSize);
    }

    if (_requestedPages.isNotEmpty) {
      pageIndex = _requestedPages.first;
      _downloadFuture = _download(pageIndex);
    } else {
      mailClient.startPolling();
    }
  }

  @override
  bool get isSequenceIdBased => true;
}

class SearchMimeSource extends MimeSource {
  final MailSearch mailSearch;
  final Mailbox mailbox;
  MailSearchResult searchResult;
  int _size = 0;
  int loadedPage = 1;
  List<MimeMessage> messages;
  final _requestedPages = <int>[];

  SearchMimeSource(MailClient mailClient, this.mailSearch, this.mailbox)
      : super(mailClient);

  @override
  Future<List<DeleteResult>> deleteAllMessages() async {
    if (_size == 0) {
      return [];
    }
    final deleteResult =
        await mailClient.deleteMessages(searchResult.messageSequence);
    searchResult = MailSearchResult.empty;
    _size = 0;
    return [deleteResult];
  }

  @override
  Future<bool> init() async {
    searchResult = await mailClient.searchMessages(mailSearch);
    messages = searchResult.messages.elements;
    _size = searchResult.size;
    return true;
  }

  @override
  matches(MimeMessage message) {
    return mailSearch.matches(message);
  }

  @override
  bool get isArchive => mailbox.isArchive;

  @override
  bool get isJunk => mailbox.isJunk;

  @override
  bool get isTrash => mailbox.isTrash;

  @override
  String get name => mailSearch.query;

  @override
  MimeSource search(MailSearch search) {
    throw UnimplementedError();
  }

  @override
  bool get shouldBlockImages => isTrash || isJunk;

  @override
  int get size => _size;

  @override
  bool get supportsSearching => false;

  @override
  bool get suppportsDeleteAll => true;

  @override
  MimeMessage getMessageAt(int index) {
    if (index < messages.length) {
      return messages[index];
    }
    _queue(index);
    final message = MimeMessage();
    final id = searchResult.messageSequence
        .elementAt(_size - 1 - index); // sequence is loaded from end to front
    if (searchResult.messageSequence.isUidSequence) {
      message.uid = id;
    } else {
      message.sequenceId = id;
    }
    return message;
  }

  void _queue(int index) {
    final pageSize = searchResult.messages.pageSize;
    final pageIndex = index ~/ pageSize;
    if (_requestedPages.contains(pageIndex)) {
      return;
    }
    _requestedPages.insert(0, pageIndex);
    if (_requestedPages.length > 5) {
      // just skip the olded referenced messages
      _requestedPages.removeLast();
    }
    if (_requestedPages.length == 1) {
      _downloadFuture = _download(pageIndex);
    }
  }

  Future<void> _download(int pageIndex) async {
    //print('downloading $pageIndex');
    await mailClient.stopPollingIfNeeded();
    final pageSize = searchResult.messages.pageSize;
    final requestSequence = searchResult.messageSequence
        .subsequenceFromPage(pageIndex + 1, pageSize);
    final mimeMessages = await mailClient.fetchMessageSequence(requestSequence,
        fetchPreference: FetchPreference.envelope);
    _requestedPages.remove(pageIndex);
    for (final mime in mimeMessages) {
      messages.add(mime);
      _notifyLoaded(mime);
    }
    if (_requestedPages.isNotEmpty) {
      pageIndex = _requestedPages.first;
      _downloadFuture = _download(pageIndex);
    } else {
      mailClient.startPolling();
    }
  }

  @override
  void addMessage(MimeMessage message) {
    messages.insert(0, message);
    _size++;
  }

  @override
  void remove(MimeMessage mimeMessage) {
    if (messages.remove(mimeMessage)) {
      _size--;
    }
  }

  @override
  void removeVanishedMessages(MessageSequence sequence) {
    final ids = sequence.toList();
    MimeMessage message;
    for (var id in ids) {
      if (sequence.isUidSequence == true) {
        message =
            messages.firstWhere((msg) => msg.uid == id, orElse: () => null);
      } else {
        message = messages.firstWhere((msg) => msg.sequenceId == id,
            orElse: () => null);
      }
      if (message != null) {
        remove(message);
        _notifyVanished(message);
      }
    }
  }

  @override
  bool get isSequenceIdBased =>
      !(searchResult?.messageSequence?.isUidSequence ?? false);
}
