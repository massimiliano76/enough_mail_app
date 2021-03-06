import 'package:enough_mail/enough_mail.dart';
import 'package:enough_mail_app/events/account_change_event.dart';
import 'package:enough_mail_app/events/app_event_bus.dart';
import 'package:enough_mail_app/models/account.dart';
import 'package:enough_mail_app/models/message_source.dart';
import 'package:enough_mail_app/models/mime_source.dart';
import 'package:enough_mail_app/models/sender.dart';
import 'package:enough_mail_app/services/settings_service.dart';
import 'package:enough_serialization/enough_serialization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:simple_gravatar/simple_gravatar.dart';

import '../locator.dart';

class MailService {
  static const String attributeGravatarImageUrl = 'gravatar.img';
  static const String attributeExcludeFromUnified = 'excludeUnified';
  static const String attributePlusAliasTested = 'test.alias.plus';
  static const String attributeSentMailAddedAutomatically = 'sendMailAdded';
  //MailClient current;
  MessageSource messageSource;
  Account currentAccount;
  List<MailAccount> mailAccounts = <MailAccount>[];
  final accounts = <Account>[];
  UnifiedAccount unifiedAccount;

  static const String _keyAccounts = 'accts';
  FlutterSecureStorage _storage;
  final _mailClientsPerAccount = <Account, MailClient>{};
  final _mailboxesPerAccount = <Account, Tree<Mailbox>>{};

  Future<void> init() async {
    _registerForEvents();
    await _loadAccounts();
    messageSource = await _initMessageSource();
  }

  Future<void> _loadAccounts() async {
    mailAccounts = await loadMailAccounts();
    for (var mailAccount in mailAccounts) {
      accounts.add(Account(mailAccount));
    }
    _createUnifiedAccount();
  }

  Future<List<MailAccount>> loadMailAccounts() async {
    _storage ??= FlutterSecureStorage();
    var json = await _storage.read(key: _keyAccounts);
    if (json != null) {
      final accounts = <MailAccount>[];
      Serializer().deserializeList(json, accounts, (map) => MailAccount());
      return accounts;
    }
    return <MailAccount>[];
  }

  _createUnifiedAccount() {
    final mailAccountsForUnified = accounts
        .where((account) => (!account.isVirtual &&
            !account.account.hasAttribute(attributeExcludeFromUnified)))
        .toList();
    if (mailAccountsForUnified.length > 1) {
      unifiedAccount = UnifiedAccount(mailAccountsForUnified);
      accounts.insert(0, unifiedAccount);
      final mailboxes = [
        Mailbox()
          ..name = 'Unified Inbox'
          ..flags = [MailboxFlag.inbox],
        Mailbox()
          ..name = 'Unified Drafts'
          ..flags = [MailboxFlag.drafts],
        Mailbox()
          ..name = 'Unified Sent'
          ..flags = [MailboxFlag.sent],
        Mailbox()
          ..name = 'Unified Trash'
          ..flags = [MailboxFlag.trash],
        Mailbox()
          ..name = 'Unified Archive'
          ..flags = [MailboxFlag.archive],
        Mailbox()
          ..name = 'Unified Spam'
          ..flags = [MailboxFlag.junk],
      ];
      final tree = Tree<Mailbox>(Mailbox())
        ..populateFromList(mailboxes, (child) => null);
      _mailboxesPerAccount[unifiedAccount] = tree;
    }
  }

  Future<MessageSource> _initMessageSource() {
    if (unifiedAccount != null) {
      currentAccount = unifiedAccount;
    } else if (accounts.isNotEmpty) {
      currentAccount = accounts.first;
    }
    if (currentAccount != null) {
      return _createMessageSource(null, currentAccount);
    }
    return null;
  }

  Future<MessageSource> _createMessageSource(
      Mailbox mailbox, Account account) async {
    if (account is UnifiedAccount) {
      final mimeSources = await _getUnifiedMimeSources(mailbox, account);
      return MultipleMessageSource(
        mimeSources,
        mailbox == null ? 'Unified Inbox' : mailbox.name,
        mailbox?.flags?.first ?? MailboxFlag.inbox,
      );
    } else {
      var mailClient = await getClientFor(account);
      await mailClient.stopPollingIfNeeded();
      return MailboxMessageSource(mailbox, mailClient);
    }
  }

  Future<List<MimeSource>> _getUnifiedMimeSources(
      Mailbox mailbox, UnifiedAccount unifiedAccount) async {
    final futures = <Future>[];
    final mimeSources = <MimeSource>[];
    MailboxFlag flag = mailbox?.flags?.first;
    for (final subAccount in unifiedAccount.accounts) {
      futures.add(_getClientAndStopPolling(subAccount));
    }
    final clients = await Future.wait(futures);
    for (final client in clients) {
      Mailbox accountMailbox;
      if (flag != null) {
        accountMailbox = client.getMailbox(flag);
        if (accountMailbox == null) {
          print(
              'unable to find mailbox with $flag in account ${client.account.name}');
          continue;
        }
      }
      mimeSources.add(MailboxMimeSource(client, accountMailbox));
    }
    return mimeSources;
  }

  Future<MailClient> _getClientAndStopPolling(Account account) async {
    final client = await getClientFor(account);
    await client.stopPollingIfNeeded();
    return client;
  }

  void _addGravatar(MailAccount account) {
    final gravatar = Gravatar(account.email);
    final url = gravatar.imageUrl(
      size: 400,
      defaultImage: GravatarImage.retro,
    );
    account.attributes[attributeGravatarImageUrl] = url;
  }

  Future<bool> addAccount(
      MailAccount mailAccount, MailClient mailClient) async {
    currentAccount = Account(mailAccount);
    accounts.add(currentAccount);
    await loadMailboxesFor(mailClient);
    _mailClientsPerAccount[currentAccount] = mailClient;
    await _checkForAddingSentMessages(mailAccount);
    _addGravatar(mailAccount);
    mailAccounts.add(mailAccount);
    if (!mailAccount.hasAttribute(attributeExcludeFromUnified)) {
      if (unifiedAccount != null) {
        unifiedAccount.accounts.add(currentAccount);
      } else {
        _createUnifiedAccount();
      }
    }
    final source = await getMessageSourceFor(currentAccount);
    messageSource = source;
    AppEventBus.eventBus.fire(AccountChangeEvent(mailClient, mailAccount));
    await _saveAccounts();
    return true;
  }

  void _registerForEvents() {
    AppEventBus.eventBus.on<AppLifecycleState>().listen((e) async {
      if (e == AppLifecycleState.resumed) {
        // the application has been resumed from the background
        //TODO let current mail source resume its work:
        //await mailSource.resume();
      }
    });
  }

  List<Sender> getSenders({bool includePlaceholdersForPlusAliases = true}) {
    final senders = <Sender>[];
    for (final account in accounts) {
      if (account.isVirtual) {
        continue;
      }
      senders.add(Sender(account.fromAddress, account));
      if (account.aliases != null) {
        for (final alias in account.aliases) {
          senders.add(Sender(alias, account));
        }
      }
      if (includePlaceholdersForPlusAliases) {
        if (account.supportsPlusAliases ||
            !hasAccountBeenTestedForPlusAlias(account)) {
          senders.add(Sender(null, account, isPlaceHolderForPlusAlias: true));
        }
      }
    }
    return senders;
  }

  MessageBuilder mailto(Uri mailto, MimeMessage originatingMessage) {
    final senders = getSenders(includePlaceholdersForPlusAliases: false);
    final searchFor = senders.map((s) => s.address).toList();
    final searchIn = originatingMessage.recipientAddresses
        .map((email) => MailAddress('', email))
        .toList();
    var fromAddress = MailAddress.getMatch(searchFor, searchIn);
    if (fromAddress == null) {
      final settings = locator<SettingsService>().settings;
      if (settings.preferredComposeMailAddress != null) {
        fromAddress = searchFor.firstWhere(
            (address) => address.email == settings.preferredComposeMailAddress,
            orElse: () => null);
      }
      fromAddress ??= searchFor.first;
    }
    return MessageBuilder.prepareMailtoBasedMessage(mailto, fromAddress);
  }

  Future<void> _saveAccounts() {
    final json = Serializer().serializeList(mailAccounts);
    print(json);
    _storage ??= FlutterSecureStorage();
    return _storage.write(key: _keyAccounts, value: json);
  }

  Future<MailClient> getClientFor(Account account) async {
    var client = _mailClientsPerAccount[account];
    if (client == null) {
      client = MailClient(account.account,
          eventBus: AppEventBus.eventBus,
          isLogEnabled: true,
          logName: account.account.name);
      _mailClientsPerAccount[account] = client;
      await client.connect();
      await loadMailboxesFor(client);
    }
    return client;
  }

  Future<MailClient> getClientForAccountWithEmail(String accountEmail) {
    final account = getAccountForEmail(accountEmail);
    return getClientFor(account);
  }

  Future<MessageSource> getMessageSourceFor(Account account,
      {Mailbox mailbox, bool switchToAccount}) async {
    var source = await _createMessageSource(mailbox, account);
    if (switchToAccount == true) {
      messageSource = source;
      currentAccount = account;
    }
    return source;
  }

  Account getAccountFor(MailAccount mailAccount) {
    return accounts.firstWhere((a) => a.account == mailAccount,
        orElse: () => null);
  }

  Account getAccountForEmail(String accountEmail) {
    return accounts.firstWhere((a) => a.email == accountEmail,
        orElse: () => null);
  }

  Future<void> loadMailboxesFor(MailClient client) async {
    final account = getAccountFor(client.account);
    if (account == null) {
      print('Unable to find account for ${client.account}');
      return;
    }
    final mailboxTree =
        await client.listMailboxesAsTree(createIntermediate: false);
    _mailboxesPerAccount[account] = mailboxTree;
  }

  Tree<Mailbox> getMailboxTreeFor(Account account) {
    return _mailboxesPerAccount[account];
  }

  Future<void> saveAccount(MailAccount account) {
    // print('saving account ${account.name}');
    return _saveAccounts();
  }

  void markAccountAsTestedForPlusAlias(Account account) {
    account.account.attributes[attributePlusAliasTested] = true;
  }

  bool hasAccountBeenTestedForPlusAlias(Account account) {
    return account?.account?.attributes[attributePlusAliasTested] ?? false;
  }

  /// Creates a new random plus alias based on the primary email address of this account.
  String generateRandomPlusAlias(Account account) {
    final mail = account.email;
    final atIndex = mail.lastIndexOf('@');
    if (atIndex == -1) {
      throw StateError(
          'unable to create alias based on invalid email <$mail>.');
    }
    final random = MessageBuilder.createRandomId(length: 8);
    return mail.substring(0, atIndex) + '+' + random + mail.substring(atIndex);
  }

  Sender generateRandomPlusAliasSender(Sender sender) {
    final email = generateRandomPlusAlias(sender.account);
    return Sender(MailAddress(null, email), sender.account);
  }

  Future<void> removeAccount(Account account) async {
    accounts.remove(account);
    mailAccounts.remove(account.account);
    _mailboxesPerAccount[account] = null;
    _mailClientsPerAccount[account] = null;
    // TODO handle the case when an account is removed that is used in the current mail source
    // if (current?.account == account) {
    //   await current.disconnect();
    //   if (accounts.isNotEmpty) {
    //     current = await getClientFor(accounts.first);
    //   } else {
    //     current = null;
    //   }
    // }
    await _saveAccounts();
  }

  String getEmailDomain(String email) {
    final startIndex = email.lastIndexOf('@');
    if (startIndex == -1) {
      return null;
    }
    return email.substring(startIndex + 1);
  }

  Future<MailClient> connect(MailAccount mailAccount) async {
    var mailClient = MailClient(mailAccount,
        isLogEnabled: true, eventBus: AppEventBus.eventBus);
    try {
      await mailClient.connect();
    } on MailException {
      var preferredUserName =
          mailAccount.incoming.serverConfig.getUserName(mailAccount.userName);
      if (preferredUserName == null || preferredUserName == mailAccount.email) {
        final atIndex = mailAccount.email.lastIndexOf('@');
        preferredUserName = mailAccount.email.substring(0, atIndex);
        final incomingAuth = mailAccount.incoming.authentication;
        if (incomingAuth is PlainAuthentication) {
          incomingAuth.userName = preferredUserName;
        }
        final outgoingAuth = mailAccount.outgoing.authentication;
        if (outgoingAuth is PlainAuthentication) {
          outgoingAuth.userName = preferredUserName;
        }
        mailClient = MailClient(mailAccount,
            isLogEnabled: true, eventBus: AppEventBus.eventBus);
        try {
          await mailClient.connect();
        } on MailException {
          return null;
        }
      }
    }
    return mailClient;
  }

  Future _checkForAddingSentMessages(MailAccount mailAccount) async {
    mailAccount.attributes[attributeSentMailAddedAutomatically] = [
      'outlook.office365.com',
      'imap.gmail.com'
    ].contains(mailAccount.incoming.serverConfig.hostname);
    //TODO later test sending of messages
  }

  List<MailClient> getMailClients() {
    final mailClients = <MailClient>[];
    final existingMailClients = _mailClientsPerAccount.values;
    for (final mailAccount in mailAccounts) {
      var client = existingMailClients.firstWhere(
          (client) => client.account == mailAccount,
          orElse: () => null);
      client ??= MailClient(mailAccount);
      mailClients.add(client);
    }
    return mailClients;
  }

  /// Checks the connection status and resumes the connection if necessary
  Future resume() {
    final futures = <Future>[];
    for (final client in _mailClientsPerAccount.values) {
      futures.add(client.resume());
    }
    return Future.wait(futures);
  }
}
