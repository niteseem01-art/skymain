import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const SkyMainApp());
}

String getPrivateChatId(String uid1, String uid2) {
  final ids = [uid1, uid2]..sort();
  return ids.join('_');
}

String getFriendRequestId(String uid1, String uid2) {
  final ids = [uid1, uid2]..sort();
  return ids.join('_');
}

Future<void> setCurrentUserOnlineStatus(bool isOnline) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
    'isOnline': isOnline,
    'lastSeen': FieldValue.serverTimestamp(),
    'updatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}

Future<void> setupNotificationsForCurrentUser() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  try {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    final token = await messaging.getToken();

    if (token != null) {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    }

    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser == null) return;

      await FirebaseFirestore.instance
          .collection('users')
          .doc(currentUser.uid)
          .set({
        'fcmTokens': FieldValue.arrayUnion([newToken]),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  } catch (_) {
    // FCM may not work on every desktop/browser setup.
  }
}

Future<void> signOutCurrentUser() async {
  await setCurrentUserOnlineStatus(false);
  await FirebaseAuth.instance.signOut();
}

Future<String?> createPrivateChatDocument(String otherUid) async {
  final currentUser = FirebaseAuth.instance.currentUser;
  if (currentUser == null) return null;

  final chatId = getPrivateChatId(currentUser.uid, otherUid);
  final ids = [currentUser.uid, otherUid]..sort();

  await FirebaseFirestore.instance.collection('chats').doc(chatId).set({
    'chatId': chatId,
    'type': 'private',
    'members': ids,
    'lastMessage': '',
    'disappearSeconds': 0,
    'typing': {},
    'updatedAt': FieldValue.serverTimestamp(),
    'createdAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));

  return chatId;
}

Future<void> showAppSnack(BuildContext context, String text) async {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

class SkyMainApp extends StatelessWidget {
  const SkyMainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SkyMain',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F1117),
        cardColor: const Color(0xFF1E222A),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5865F2),
          brightness: Brightness.dark,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF16191F),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
        ),
        useMaterial3: true,
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(body: Center(child: CircularProgressIndicator()));
          }
          return snapshot.hasData ? const HomePage() : const LoginPage();
        },
      ),
    );
  }
}

class LoginPage extends StatelessWidget {
  const LoginPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AuthCard(
      title: 'SkyMain',
      subtitle: 'Welcome back',
      buttonText: 'Login',
      bottomText: 'Create an account',
      isRegister: false,
      onBottomPressed: () {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const RegisterPage()));
      },
    );
  }
}

class RegisterPage extends StatelessWidget {
  const RegisterPage({super.key});

  @override
  Widget build(BuildContext context) {
    return AuthCard(
      title: 'Create Account',
      subtitle: 'Join SkyMain today',
      buttonText: 'Register',
      bottomText: 'Already have an account?',
      isRegister: true,
      onBottomPressed: () => Navigator.pop(context),
    );
  }
}

class AuthCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final String buttonText;
  final String bottomText;
  final bool isRegister;
  final VoidCallback onBottomPressed;

  const AuthCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.buttonText,
    required this.bottomText,
    required this.isRegister,
    required this.onBottomPressed,
  });

  @override
  State<AuthCard> createState() => _AuthCardState();
}

class _AuthCardState extends State<AuthCard> {
  final usernameController = TextEditingController();
  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  bool isLoading = false;
  String? errorMessage;

  Future<void> resetPassword() async {
    final controller = TextEditingController(text: emailController.text.trim());
    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Reset password'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final email = controller.text.trim();
                if (email.isEmpty) return;
                await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                if (mounted) showAppSnack(context, 'Password reset email sent.');
              },
              child: const Text('Send'),
            ),
          ],
        );
      },
    );
    controller.dispose();
  }

  Future<void> submit() async {
    setState(() {
      isLoading = true;
      errorMessage = null;
    });

    try {
      final username = usernameController.text.trim();
      final email = emailController.text.trim();
      final password = passwordController.text.trim();

      if (email.isEmpty || password.isEmpty) {
        setState(() => errorMessage = 'Please enter your email and password.');
        return;
      }

      if (widget.isRegister && username.isEmpty) {
        setState(() => errorMessage = 'Please enter a username.');
        return;
      }

      if (widget.isRegister) {
        final existingUsername = await FirebaseFirestore.instance
            .collection('users')
            .where('usernameLower', isEqualTo: username.toLowerCase())
            .limit(1)
            .get();

        if (existingUsername.docs.isNotEmpty) {
          setState(() => errorMessage = 'That username is already taken.');
          return;
        }

        final credential = await FirebaseAuth.instance.createUserWithEmailAndPassword(email: email, password: password);
        final user = credential.user;

        if (user != null) {
          await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
            'uid': user.uid,
            'email': email,
            'username': username,
            'usernameLower': username.toLowerCase(),
            'photoUrl': '',
            'blockedUsers': [],
            'showOnlineStatus': true,
            'showReadReceipts': true,
            'isOnline': true,
            'lastSeen': FieldValue.serverTimestamp(),
            'createdAt': FieldValue.serverTimestamp(),
            'updatedAt': FieldValue.serverTimestamp(),
          });
          await setupNotificationsForCurrentUser();
        }
      } else {
        await FirebaseAuth.instance.signInWithEmailAndPassword(email: email, password: password);
        await setCurrentUserOnlineStatus(true);
        await setupNotificationsForCurrentUser();
      }
    } on FirebaseAuthException catch (e) {
      setState(() => errorMessage = e.message ?? 'Authentication failed.');
    } catch (e) {
      setState(() => errorMessage = 'Something went wrong: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  @override
  void dispose() {
    usernameController.dispose();
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Container(
          width: 390,
          margin: const EdgeInsets.all(18),
          padding: const EdgeInsets.all(26),
          decoration: BoxDecoration(
            color: const Color(0xFF1E222A),
            borderRadius: BorderRadius.circular(26),
            boxShadow: const [BoxShadow(blurRadius: 30, color: Colors.black26)],
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.bolt, size: 46, color: Color(0xFF5865F2)),
                const SizedBox(height: 10),
                Text(widget.title, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                Text(widget.subtitle, style: const TextStyle(color: Colors.white70)),
                const SizedBox(height: 28),
                if (widget.isRegister) ...[
                  TextField(controller: usernameController, decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person_outline))),
                  const SizedBox(height: 14),
                ],
                TextField(controller: emailController, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email', prefixIcon: Icon(Icons.email_outlined))),
                const SizedBox(height: 14),
                TextField(controller: passwordController, obscureText: true, decoration: const InputDecoration(labelText: 'Password', prefixIcon: Icon(Icons.lock_outline))),
                if (!widget.isRegister) ...[
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(onPressed: resetPassword, child: const Text('Forgot password?')),
                  ),
                ],
                if (errorMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(errorMessage!, style: const TextStyle(color: Colors.redAccent), textAlign: TextAlign.center),
                ],
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: isLoading ? null : submit,
                    child: isLoading
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(widget.buttonText),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(onPressed: isLoading ? null : widget.onBottomPressed, child: Text(widget.bottomText)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class UserNameText extends StatelessWidget {
  final String uid;
  final TextStyle? style;
  final TextAlign? textAlign;

  const UserNameText({super.key, required this.uid, this.style, this.textAlign});

  @override
  Widget build(BuildContext context) {
    if (uid.isEmpty) return Text('Unknown', style: style, textAlign: textAlign);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final username = data?['username'] ?? 'Unknown';
        return Text(username, style: style, textAlign: textAlign, overflow: TextOverflow.ellipsis);
      },
    );
  }
}

class UserAvatar extends StatelessWidget {
  final String uid;
  final double radius;

  const UserAvatar({super.key, required this.uid, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    if (uid.isEmpty) return CircleAvatar(radius: radius, child: const Text('?'));

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final username = data?['username'] ?? '?';
        final photoUrl = (data?['photoUrl'] ?? '').toString();

        if (photoUrl.startsWith('http')) {
          return CircleAvatar(radius: radius, backgroundImage: NetworkImage(photoUrl));
        }

        return CircleAvatar(radius: radius, child: Text(username.isNotEmpty ? username[0].toUpperCase() : '?'));
      },
    );
  }
}

class UserProfileTile extends StatelessWidget {
  final String uid;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  const UserProfileTile({super.key, required this.uid, required this.subtitle, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFF1E222A),
      child: ListTile(
        leading: UserAvatar(uid: uid),
        title: UserNameText(uid: uid),
        subtitle: Text(subtitle, style: const TextStyle(color: Colors.white60)),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }
}

class CurrentUserNameText extends StatelessWidget {
  final TextStyle? style;
  const CurrentUserNameText({super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return Text('Unknown', style: style);
    return UserNameText(uid: user.uid, style: style);
  }
}

class OnlineStatusText extends StatelessWidget {
  final String uid;
  final bool showDisabledText;
  final bool includeNameWhenDisabled;
  final TextStyle? onlineStyle;
  final TextStyle? disabledStyle;
  final TextStyle? offlineStyle;

  const OnlineStatusText({
    super.key,
    required this.uid,
    this.showDisabledText = false,
    this.includeNameWhenDisabled = false,
    this.onlineStyle,
    this.disabledStyle,
    this.offlineStyle,
  });

  String formatLastActive(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inSeconds < 60) return 'Last active just now';
    if (diff.inMinutes < 60) return 'Last active ${diff.inMinutes} min ago';
    if (diff.inHours < 24) return 'Last active ${diff.inHours} hour${diff.inHours == 1 ? '' : 's'} ago';
    if (diff.inDays < 30) return 'Last active ${diff.inDays} day${diff.inDays == 1 ? '' : 's'} ago';
    final months = diff.inDays ~/ 30;
    return 'Last active $months month${months == 1 ? '' : 's'} ago';
  }

  bool isActuallyOnline(Map<String, dynamic>? data) {
    if (data == null) return false;
    final isOnline = data['isOnline'] ?? false;
    final lastSeen = data['lastSeen'];
    if (isOnline != true || lastSeen is! Timestamp) return false;
    final secondsSinceHeartbeat = DateTime.now().difference(lastSeen.toDate()).inSeconds;
    return secondsSinceHeartbeat <= 90;
  }

  @override
  Widget build(BuildContext context) {
    if (uid.isEmpty) return const SizedBox.shrink();

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final username = data?['username'] ?? 'This user';
        final showOnlineStatus = data?['showOnlineStatus'] ?? true;
        final lastSeen = data?['lastSeen'];

        if (!showOnlineStatus) {
          if (!showDisabledText) return const SizedBox.shrink();
          return Text(
            includeNameWhenDisabled ? '$username has turned off online activity status' : 'Online status disabled',
            style: disabledStyle ?? const TextStyle(color: Colors.white54, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          );
        }

        if (isActuallyOnline(data)) {
          return Text('Online', style: onlineStyle ?? const TextStyle(color: Colors.greenAccent, fontSize: 13));
        }

        if (lastSeen is Timestamp) {
          return Text(formatLastActive(lastSeen.toDate()), style: offlineStyle ?? const TextStyle(color: Colors.white54, fontSize: 13));
        }

        return Text('Offline', style: offlineStyle ?? const TextStyle(color: Colors.white54, fontSize: 13));
      },
    );
  }
}

class TypingStatusText extends StatelessWidget {
  final String chatId;
  final String otherUserId;

  const TypingStatusText({super.key, required this.chatId, required this.otherUserId});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('chats').doc(chatId).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final typing = data?['typing'];

        if (typing is Map<String, dynamic>) {
          final otherTyping = typing[otherUserId];
          if (otherTyping is Timestamp) {
            final diff = DateTime.now().difference(otherTyping.toDate()).inSeconds;
            if (diff <= 4) {
              return const Text('typing...', style: TextStyle(color: Colors.white54, fontSize: 11, fontStyle: FontStyle.italic));
            }
          }
        }

        return OnlineStatusText(
          uid: otherUserId,
          showDisabledText: true,
          includeNameWhenDisabled: true,
          onlineStyle: const TextStyle(color: Colors.greenAccent, fontSize: 11),
          disabledStyle: const TextStyle(color: Colors.white54, fontSize: 11),
          offlineStyle: const TextStyle(color: Colors.white54, fontSize: 11),
        );
      },
    );
  }
}

class ReadReceiptStatus extends StatelessWidget {
  final String otherUserId;
  final List<dynamic> seenBy;

  const ReadReceiptStatus({super.key, required this.otherUserId, required this.seenBy});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(otherUserId).snapshots(),
      builder: (context, snapshot) {
        final data = snapshot.data?.data();
        final username = data?['username'] ?? 'This user';
        final showReadReceipts = data?['showReadReceipts'] ?? true;

        if (!showReadReceipts) {
          return Text('$username has turned off showing read messages', style: const TextStyle(color: Colors.white38, fontSize: 10), overflow: TextOverflow.ellipsis);
        }

        final hasSeen = seenBy.contains(otherUserId);
        return Text(hasSeen ? 'Seen' : 'Sent', style: TextStyle(color: hasSeen ? Colors.greenAccent : Colors.white38, fontSize: 10));
      },
    );
  }
}

class ChatPreviewText extends StatelessWidget {
  final String chatId;
  final String currentUid;

  const ChatPreviewText({super.key, required this.chatId, required this.currentUid});

  bool isExpired(Map<String, dynamic> data) {
    final expiresAt = data['expiresAt'];
    return expiresAt is Timestamp && expiresAt.toDate().isBefore(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('chats').doc(chatId).collection('messages').orderBy('createdAt', descending: true).limit(25).snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];

        for (final doc in docs) {
          final data = doc.data() as Map<String, dynamic>;
          final deletedFor = List<dynamic>.from(data['deletedFor'] ?? []);
          if (!deletedFor.contains(currentUid) && !isExpired(data)) {
            final text = data['text'] ?? '';
            final isEdited = data['isEdited'] == true;
            return Text(isEdited ? '$text (edited)' : text, style: const TextStyle(color: Colors.white60), maxLines: 1, overflow: TextOverflow.ellipsis);
          }
        }

        return const Text('No messages yet', style: TextStyle(color: Colors.white60), maxLines: 1, overflow: TextOverflow.ellipsis);
      },
    );
  }
}

class UnreadBadge extends StatelessWidget {
  final String chatId;
  final String currentUid;

  const UnreadBadge({super.key, required this.chatId, required this.currentUid});

  bool isExpired(Map<String, dynamic> data) {
    final expiresAt = data['expiresAt'];
    return expiresAt is Timestamp && expiresAt.toDate().isBefore(DateTime.now());
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('chats').doc(chatId).collection('messages').orderBy('createdAt', descending: true).limit(100).snapshots(),
      builder: (context, snapshot) {
        final docs = snapshot.data?.docs ?? [];
        int unread = 0;

        for (final doc in docs) {
          final data = doc.data() as Map<String, dynamic>;
          final senderId = data['senderId'] ?? '';
          final seenBy = List<dynamic>.from(data['seenBy'] ?? []);
          final deletedFor = List<dynamic>.from(data['deletedFor'] ?? []);

          if (senderId != currentUid && !seenBy.contains(currentUid) && !deletedFor.contains(currentUid) && !isExpired(data)) unread++;
        }

        if (unread <= 0) return const Icon(Icons.chevron_right);

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(color: Colors.redAccent, borderRadius: BorderRadius.circular(999)),
          child: Text(unread > 99 ? '99+' : unread.toString(), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
        );
      },
    );
  }
}

String formatDisappearTime(int seconds) {
  if (seconds <= 0) return 'Off';
  if (seconds < 60) return '$seconds sec';
  if (seconds < 3600) return '${seconds ~/ 60} min';
  if (seconds < 86400) {
    final hours = seconds ~/ 3600;
    return '$hours hour${hours == 1 ? '' : 's'}';
  }
  final days = seconds ~/ 86400;
  return '$days day${days == 1 ? '' : 's'}';
}

String formatMessageTime(Timestamp? timestamp) {
  if (timestamp == null) return '';
  final date = timestamp.toDate();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final messageDay = DateTime(date.year, date.month, date.day);
  final difference = today.difference(messageDay).inDays;
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  if (difference == 0) return '$hour:$minute';
  if (difference == 1) return 'Yesterday $hour:$minute';
  return '$difference days ago $hour:$minute';
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int selectedIndex = 0;
  Timer? heartbeatTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    startHeartbeat();
    setupNotificationsForCurrentUser();
  }

  void startHeartbeat() {
    setCurrentUserOnlineStatus(true);
    heartbeatTimer?.cancel();
    heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) => setCurrentUserOnlineStatus(true));
  }

  void stopHeartbeatAndGoOffline() {
    heartbeatTimer?.cancel();
    heartbeatTimer = null;
    setCurrentUserOnlineStatus(false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) startHeartbeat();
    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused || state == AppLifecycleState.detached) stopHeartbeatAndGoOffline();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    heartbeatTimer?.cancel();
    super.dispose();
  }

  Future<void> openUserSearch() async {
    final searchController = TextEditingController();
    String? errorMessage;
    List<QueryDocumentSnapshot<Map<String, dynamic>>> results = [];

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> searchUsers() async {
              final query = searchController.text.trim().toLowerCase();
              final currentUser = FirebaseAuth.instance.currentUser;
              if (query.isEmpty) {
                setDialogState(() {
                  errorMessage = 'Enter a username.';
                  results = [];
                });
                return;
              }

              final snapshot = await FirebaseFirestore.instance.collection('users').where('usernameLower', isEqualTo: query).limit(10).get();
              final filtered = snapshot.docs.where((doc) => doc.data()['uid'] != currentUser?.uid).toList();

              setDialogState(() {
                results = filtered;
                errorMessage = filtered.isEmpty ? 'No user found.' : null;
              });
            }

            return AlertDialog(
              title: const Text('Find user'),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: searchController, decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.search)), onSubmitted: (_) => searchUsers()),
                    const SizedBox(height: 12),
                    SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: searchUsers, icon: const Icon(Icons.search), label: const Text('Search'))),
                    if (errorMessage != null) ...[
                      const SizedBox(height: 12),
                      Text(errorMessage!, style: const TextStyle(color: Colors.redAccent)),
                    ],
                    const SizedBox(height: 12),
                    ...results.map((doc) {
                      final data = doc.data();
                      final otherUid = data['uid'] ?? '';
                      return UserProfileTile(
                        uid: otherUid,
                        subtitle: data['email'] ?? '',
                        trailing: const Icon(Icons.person_add_alt),
                        onTap: () async {
                          Navigator.pop(dialogContext);
                          await handleUserSearchAction(data);
                        },
                      );
                    }),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    searchController.dispose();
  }

  Future<void> handleUserSearchAction(Map<String, dynamic> otherUserData) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;

    final otherUid = otherUserData['uid'];
    final currentDoc = await FirebaseFirestore.instance.collection('users').doc(currentUser.uid).get();
    final blockedUsers = List<dynamic>.from(currentDoc.data()?['blockedUsers'] ?? []);

    if (blockedUsers.contains(otherUid)) {
      if (!mounted) return;
      showAppSnack(context, 'You have blocked this user.');
      return;
    }

    final requestId = getFriendRequestId(currentUser.uid, otherUid);
    final requestRef = FirebaseFirestore.instance.collection('friendRequests').doc(requestId);
    final requestDoc = await requestRef.get();
    final requestData = requestDoc.data();

    if (requestDoc.exists && requestData?['status'] == 'accepted') {
      final chatId = await createPrivateChatDocument(otherUid);
      if (!mounted || chatId == null) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(chatId: chatId, otherUserId: otherUid)));
      return;
    }

    if (requestDoc.exists && requestData?['status'] == 'pending') {
      if (!mounted) return;
      showAppSnack(context, 'Friend request already pending.');
      return;
    }

    await requestRef.set({
      'requestId': requestId,
      'fromUid': currentUser.uid,
      'toUid': otherUid,
      'participants': [currentUser.uid, otherUid],
      'status': 'pending',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (!mounted) return;
    showAppSnack(context, 'Friend request sent.');
  }

  Future<void> openChatWithUser(String otherUid) async {
    final chatId = await createPrivateChatDocument(otherUid);
    if (!mounted || chatId == null) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(chatId: chatId, otherUserId: otherUid)));
  }

  Future<void> logout() async {
    heartbeatTimer?.cancel();
    await signOutCurrentUser();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 760;
    final pages = [
      ChatsPage(onSearchUser: openUserSearch, onLogout: logout),
      FriendsPage(onSearchUser: openUserSearch, onOpenChat: openChatWithUser),
      BlockedUsersPage(onOpenChat: openChatWithUser),
      ProfilePage(onLogout: logout),
    ];

    return Scaffold(
      body: Row(
        children: [
          if (isDesktop)
            Container(
              width: 245,
              color: const Color(0xFF16191F),
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  const Icon(Icons.bolt, size: 34, color: Color(0xFF5865F2)),
                  const Text('SkyMain', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: CurrentUserNameText(style: TextStyle(color: Colors.white54, fontSize: 13))),
                  const SizedBox(height: 24),
                  _NavTile(icon: Icons.chat_bubble_outline, label: 'Chats', selected: selectedIndex == 0, onTap: () => setState(() => selectedIndex = 0)),
                  _NavTile(icon: Icons.people_outline, label: 'Friends', selected: selectedIndex == 1, onTap: () => setState(() => selectedIndex = 1)),
                  _NavTile(icon: Icons.block, label: 'Blocked', selected: selectedIndex == 2, onTap: () => setState(() => selectedIndex = 2)),
                  _NavTile(icon: Icons.person_outline, label: 'Profile', selected: selectedIndex == 3, onTap: () => setState(() => selectedIndex = 3)),
                  const Spacer(),
                  Padding(padding: const EdgeInsets.all(16), child: FilledButton.icon(onPressed: logout, icon: const Icon(Icons.logout), label: const Text('Logout'))),
                ],
              ),
            ),
          Expanded(child: pages[selectedIndex]),
        ],
      ),
      bottomNavigationBar: isDesktop
          ? null
          : NavigationBar(
              selectedIndex: selectedIndex,
              onDestinationSelected: (index) => setState(() => selectedIndex = index),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Chats'),
                NavigationDestination(icon: Icon(Icons.people_outline), label: 'Friends'),
                NavigationDestination(icon: Icon(Icons.block), label: 'Blocked'),
                NavigationDestination(icon: Icon(Icons.person_outline), label: 'Profile'),
              ],
            ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _NavTile({required this.icon, required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: ListTile(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        leading: Icon(icon),
        title: Text(label),
        selected: selected,
        onTap: onTap,
      ),
    );
  }
}

class ChatsPage extends StatelessWidget {
  final VoidCallback onSearchUser;
  final VoidCallback onLogout;

  const ChatsPage({super.key, required this.onSearchUser, required this.onLogout});

  String getOtherUserId(Map<String, dynamic> data, String currentUid) {
    final members = List<String>.from(data['members'] ?? []);
    for (final uid in members) {
      if (uid != currentUid) return uid;
    }
    return '';
  }

  Future<void> deleteChatForMe(
    BuildContext context,
    String chatId,
    String currentUid,
  ) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Delete chat?'),
          content: const Text(
            'This will remove this chat from your chat list only. Messages are not deleted for the other user.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirm != true) return;

    await FirebaseFirestore.instance.collection('chats').doc(chatId).set({
      'hiddenFor': FieldValue.arrayUnion([currentUid]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    if (context.mounted) {
      showAppSnack(context, 'Chat deleted for you.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return const Center(child: Text('Not logged in.'));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chats'),
        backgroundColor: const Color(0xFF111318),
        actions: [
          IconButton(onPressed: onSearchUser, icon: const Icon(Icons.person_add_alt), tooltip: 'Find user'),
          IconButton(onPressed: onLogout, icon: const Icon(Icons.logout)),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('chats').where('members', arrayContains: currentUser.uid).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('Could not load chats.'));
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          final allChats = snapshot.data?.docs ?? [];

          final chats = allChats.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final hiddenFor = List<dynamic>.from(data['hiddenFor'] ?? []);
            return !hiddenFor.contains(currentUser.uid);
          }).toList();

          chats.sort((a, b) {
            final aTime = (a.data() as Map<String, dynamic>)['updatedAt'];
            final bTime = (b.data() as Map<String, dynamic>)['updatedAt'];
            if (aTime is Timestamp && bTime is Timestamp) return bTime.compareTo(aTime);
            return 0;
          });

          if (chats.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.chat_bubble_outline, size: 54),
                  const SizedBox(height: 12),
                  const Text('No chats yet', style: TextStyle(fontSize: 20)),
                  const SizedBox(height: 8),
                  const Text('Search a username or accept a friend request.', style: TextStyle(color: Colors.white54)),
                  const SizedBox(height: 18),
                  FilledButton.icon(onPressed: onSearchUser, icon: const Icon(Icons.person_add_alt), label: const Text('Find user')),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: chats.length,
            itemBuilder: (context, index) {
              final chatDoc = chats[index];
              final data = chatDoc.data() as Map<String, dynamic>;
              final chatId = data['chatId'] ?? chatDoc.id;
              final otherUid = getOtherUserId(data, currentUser.uid);
              final disappearSeconds = data['disappearSeconds'] ?? 0;

              return Card(
                color: const Color(0xFF1E222A),
                child: ListTile(
                  leading: UserAvatar(uid: otherUid),
                  title: Row(
                    children: [
                      Expanded(child: UserNameText(uid: otherUid)),
                      if (disappearSeconds > 0) const Icon(Icons.timer_outlined, size: 17, color: Colors.white54),
                    ],
                  ),
                  subtitle: ChatPreviewText(chatId: chatId, currentUid: currentUser.uid),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      UnreadBadge(chatId: chatId, currentUid: currentUser.uid),
                      IconButton(
                        tooltip: 'Delete chat',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => deleteChatForMe(
                          context,
                          chatId,
                          currentUser.uid,
                        ),
                      ),
                    ],
                  ),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChatPage(chatId: chatId, otherUserId: otherUid))),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton(onPressed: onSearchUser, child: const Icon(Icons.person_add_alt)),
    );
  }
}

class FriendsPage extends StatelessWidget {
  final VoidCallback onSearchUser;
  final Future<void> Function(String otherUid) onOpenChat;

  const FriendsPage({super.key, required this.onSearchUser, required this.onOpenChat});

  String getOtherUid(Map<String, dynamic> data, String currentUid) {
    final fromUid = data['fromUid'] ?? '';
    final toUid = data['toUid'] ?? '';
    return fromUid == currentUid ? toUid : fromUid;
  }

  Future<void> acceptRequest(BuildContext context, QueryDocumentSnapshot requestDoc) async {
    final data = requestDoc.data() as Map<String, dynamic>;
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    final otherUid = getOtherUid(data, currentUser.uid);
    await requestDoc.reference.update({'status': 'accepted', 'updatedAt': FieldValue.serverTimestamp()});
    await createPrivateChatDocument(otherUid);
    if (context.mounted) showAppSnack(context, 'Friend request accepted.');
  }

  Future<void> deleteRequest(BuildContext context, QueryDocumentSnapshot requestDoc) async {
    await requestDoc.reference.delete();
    if (context.mounted) showAppSnack(context, 'Request removed.');
  }

  Future<void> removeFriend(BuildContext context, String otherUid) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    final requestId = getFriendRequestId(currentUser.uid, otherUid);
    await FirebaseFirestore.instance.collection('friendRequests').doc(requestId).delete();
    if (context.mounted) showAppSnack(context, 'Friend removed.');
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return const Center(child: Text('Not logged in.'));

    return Scaffold(
      appBar: AppBar(title: const Text('Friends'), backgroundColor: const Color(0xFF111318), actions: [IconButton(onPressed: onSearchUser, icon: const Icon(Icons.person_add_alt))]),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('friendRequests').where('participants', arrayContains: currentUser.uid).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('Could not load friends.'));
          if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
          final docs = snapshot.data?.docs ?? [];
          final incoming = docs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            return data['status'] == 'pending' && data['toUid'] == currentUser.uid;
          }).toList();
          final outgoing = docs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            return data['status'] == 'pending' && data['fromUid'] == currentUser.uid;
          }).toList();
          final friends = docs.where((doc) => (doc.data() as Map<String, dynamic>)['status'] == 'accepted').toList();

          return ListView(
            padding: const EdgeInsets.all(14),
            children: [
              FilledButton.icon(onPressed: onSearchUser, icon: const Icon(Icons.person_add_alt), label: const Text('Find user')),
              const SizedBox(height: 18),
              const Text('Incoming Requests', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (incoming.isEmpty) const Text('No incoming requests.', style: TextStyle(color: Colors.white54)),
              ...incoming.map((doc) {
                final otherUid = getOtherUid(doc.data() as Map<String, dynamic>, currentUser.uid);
                return UserProfileTile(
                  uid: otherUid,
                  subtitle: 'Wants to be friends',
                  trailing: Wrap(spacing: 8, children: [
                    IconButton(onPressed: () => acceptRequest(context, doc), icon: const Icon(Icons.check)),
                    IconButton(onPressed: () => deleteRequest(context, doc), icon: const Icon(Icons.close)),
                  ]),
                );
              }),
              const SizedBox(height: 18),
              const Text('Friends', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (friends.isEmpty) const Text('No friends yet.', style: TextStyle(color: Colors.white54)),
              ...friends.map((doc) {
                final otherUid = getOtherUid(doc.data() as Map<String, dynamic>, currentUser.uid);
                return UserProfileTile(
                  uid: otherUid,
                  subtitle: 'Friend',
                  trailing: Wrap(spacing: 6, children: [
                    IconButton(onPressed: () => onOpenChat(otherUid), icon: const Icon(Icons.chat_bubble_outline)),
                    IconButton(onPressed: () => removeFriend(context, otherUid), icon: const Icon(Icons.person_remove_alt_1_outlined)),
                  ]),
                );
              }),
              const SizedBox(height: 18),
              const Text('Outgoing Requests', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (outgoing.isEmpty) const Text('No outgoing requests.', style: TextStyle(color: Colors.white54)),
              ...outgoing.map((doc) {
                final otherUid = getOtherUid(doc.data() as Map<String, dynamic>, currentUser.uid);
                return UserProfileTile(uid: otherUid, subtitle: 'Request sent', trailing: IconButton(onPressed: () => deleteRequest(context, doc), icon: const Icon(Icons.cancel_outlined)));
              }),
            ],
          );
        },
      ),
    );
  }
}

class BlockedUsersPage extends StatelessWidget {
  final Future<void> Function(String otherUid) onOpenChat;

  const BlockedUsersPage({super.key, required this.onOpenChat});

  Future<void> unblock(BuildContext context, String uid) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
      'blockedUsers': FieldValue.arrayRemove([uid]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    if (context.mounted) showAppSnack(context, 'User unblocked.');
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Center(child: Text('Not logged in.'));

    return Scaffold(
      appBar: AppBar(title: const Text('Blocked Users'), backgroundColor: const Color(0xFF111318)),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
        builder: (context, snapshot) {
          final data = snapshot.data?.data();
          final blocked = List<String>.from(data?['blockedUsers'] ?? []);
          if (blocked.isEmpty) return const Center(child: Text('No blocked users.', style: TextStyle(color: Colors.white54)));
          return ListView.builder(
            padding: const EdgeInsets.all(14),
            itemCount: blocked.length,
            itemBuilder: (context, index) {
              final uid = blocked[index];
              return UserProfileTile(
                uid: uid,
                subtitle: 'Blocked user',
                trailing: Wrap(spacing: 6, children: [
                  IconButton(onPressed: () => unblock(context, uid), icon: const Icon(Icons.lock_open)),
                ]),
              );
            },
          );
        },
      ),
    );
  }
}

class ProfilePage extends StatefulWidget {
  final VoidCallback onLogout;
  const ProfilePage({super.key, required this.onLogout});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final usernameController = TextEditingController();
  final photoUrlController = TextEditingController();
  bool isLoading = false;
  String? message;
  bool hasFilledProfile = false;

  Future<void> updateProfile() async {
    final user = FirebaseAuth.instance.currentUser;
    final newUsername = usernameController.text.trim();
    final photoUrl = photoUrlController.text.trim();
    if (user == null) return;
    if (newUsername.isEmpty) {
      setState(() => message = 'Username cannot be empty.');
      return;
    }
    setState(() {
      isLoading = true;
      message = null;
    });

    try {
      final existingUsername = await FirebaseFirestore.instance.collection('users').where('usernameLower', isEqualTo: newUsername.toLowerCase()).limit(1).get();
      final isTakenBySomeoneElse = existingUsername.docs.any((doc) => doc.id != user.uid);
      if (isTakenBySomeoneElse) {
        setState(() => message = 'That username is already taken.');
        return;
      }
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'username': newUsername,
        'usernameLower': newUsername.toLowerCase(),
        'photoUrl': photoUrl,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      setState(() => message = 'Profile updated.');
    } catch (e) {
      setState(() => message = 'Failed to update profile: $e');
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  Future<void> updateOnlineStatusVisibility(bool value) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({'showOnlineStatus': value, 'lastSeen': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
  }

  Future<void> updateReadReceiptVisibility(bool value) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({'showReadReceipts': value, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
  }

  Future<void> changePassword() async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Change password'),
        content: TextField(controller: controller, obscureText: true, decoration: const InputDecoration(labelText: 'New password')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final password = controller.text.trim();
              if (password.length < 6) return;
              await FirebaseAuth.instance.currentUser?.updatePassword(password);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (mounted) showAppSnack(context, 'Password changed.');
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> changeEmail() async {
    final controller = TextEditingController(text: FirebaseAuth.instance.currentUser?.email ?? '');
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Change email'),
        content: TextField(controller: controller, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'New email')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final newEmail = controller.text.trim();
              if (newEmail.isEmpty) return;
              await FirebaseAuth.instance.currentUser?.verifyBeforeUpdateEmail(newEmail);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
              if (mounted) showAppSnack(context, 'Verification email sent to the new address.');
            },
            child: const Text('Send verification'),
          ),
        ],
      ),
    );
    controller.dispose();
  }

  Future<void> deleteAccount() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text('This is permanent. You may need to log in again first if Firebase asks for recent login.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    await FirebaseFirestore.instance.collection('users').doc(user.uid).set({'deleted': true, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    await user.delete();
  }

  @override
  void dispose() {
    usernameController.dispose();
    photoUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return const Scaffold(body: Center(child: Text('Not logged in.')));

    return Scaffold(
      appBar: AppBar(title: const Text('Profile'), backgroundColor: const Color(0xFF111318)),
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance.collection('users').doc(user.uid).snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final data = snapshot.data?.data();
          final currentUsername = data?['username'] ?? 'Unknown';
          final currentPhotoUrl = data?['photoUrl'] ?? '';
          final showOnlineStatus = data?['showOnlineStatus'] ?? true;
          final showReadReceipts = data?['showReadReceipts'] ?? true;

          if (!hasFilledProfile) {
            usernameController.text = currentUsername;
            photoUrlController.text = currentPhotoUrl;
            hasFilledProfile = true;
          }

          return Center(
            child: Container(
              width: 500,
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(color: const Color(0xFF1E222A), borderRadius: BorderRadius.circular(24)),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Your Profile', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 18),
                    Center(
                      child: Column(
                        children: [
                          UserAvatar(uid: user.uid, radius: 42),
                          const SizedBox(height: 10),
                          Text(currentUsername, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          OnlineStatusText(uid: user.uid, showDisabledText: true, includeNameWhenDisabled: false),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text('Email: ${user.email ?? 'Unknown'}', style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 18),
                    TextField(controller: usernameController, decoration: const InputDecoration(labelText: 'Username', prefixIcon: Icon(Icons.person_outline))),
                    const SizedBox(height: 14),
                    TextField(controller: photoUrlController, decoration: const InputDecoration(labelText: 'Profile picture URL', hintText: 'https://example.com/photo.png', prefixIcon: Icon(Icons.image_outlined))),
                    const SizedBox(height: 14),
                    SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Show online status'), subtitle: Text(showOnlineStatus ? 'Other users can see when you are online or last active.' : 'Other users will see that you turned off online activity status.', style: const TextStyle(color: Colors.white54)), value: showOnlineStatus, onChanged: updateOnlineStatusVisibility),
                    SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Show read receipts'), subtitle: Text(showReadReceipts ? 'Other users can see when you read their messages.' : 'Other users will see that you turned off showing read messages.', style: const TextStyle(color: Colors.white54)), value: showReadReceipts, onChanged: updateReadReceiptVisibility),
                    if (message != null) ...[
                      const SizedBox(height: 12),
                      Text(message!, style: TextStyle(color: message == 'Profile updated.' ? Colors.greenAccent : Colors.redAccent)),
                    ],
                    const SizedBox(height: 20),
                    SizedBox(width: double.infinity, height: 48, child: FilledButton.icon(onPressed: isLoading ? null : updateProfile, icon: isLoading ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save), label: const Text('Save profile'))),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: OutlinedButton.icon(onPressed: changeEmail, icon: const Icon(Icons.email_outlined), label: const Text('Change email'))),
                      const SizedBox(width: 10),
                      Expanded(child: OutlinedButton.icon(onPressed: changePassword, icon: const Icon(Icons.lock_outline), label: const Text('Change password'))),
                    ]),
                    const SizedBox(height: 12),
                    SizedBox(width: double.infinity, height: 48, child: OutlinedButton.icon(onPressed: widget.onLogout, icon: const Icon(Icons.logout), label: const Text('Logout'))),
                    const SizedBox(height: 12),
                    SizedBox(width: double.infinity, height: 48, child: OutlinedButton.icon(onPressed: deleteAccount, icon: const Icon(Icons.delete_forever), label: const Text('Delete account'))),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class ChatPage extends StatefulWidget {
  final String chatId;
  final String otherUserId;
  const ChatPage({super.key, required this.chatId, required this.otherUserId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final messageController = TextEditingController();
  final scrollController = ScrollController();
  Timer? typingTimer;
  DateTime? lastTypingUpdate;

  bool cleanupRunning = false;
  bool markingSeen = false;

  void scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!scrollController.hasClients) return;
      scrollController.animateTo(scrollController.position.maxScrollExtent, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    });
  }

  Future<String> getCurrentUsername() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return 'Unknown';
    final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    if (!doc.exists) return user.email ?? 'Unknown';
    return doc.data()?['username'] ?? user.email ?? 'Unknown';
  }

  bool isMessageExpired(Map<String, dynamic> data) {
    final expiresAt = data['expiresAt'];
    return expiresAt is Timestamp && expiresAt.toDate().isBefore(DateTime.now());
  }

  Future<bool> currentUserShowsReadReceipts() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    final doc = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
    return doc.data()?['showReadReceipts'] ?? true;
  }

  Future<void> setTypingStatus(bool isTyping) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final chatRef = FirebaseFirestore.instance.collection('chats').doc(widget.chatId);
    try {
      if (isTyping) {
        await chatRef.set({'typing.${user.uid}': FieldValue.serverTimestamp()}, SetOptions(merge: true));
      } else {
        await chatRef.update({'typing.${user.uid}': FieldValue.delete()});
      }
    } catch (_) {}
  }

  void handleTypingChanged(String value) {
    final now = DateTime.now();

    if (lastTypingUpdate == null ||
        now.difference(lastTypingUpdate!).inSeconds >= 2) {
      lastTypingUpdate = now;
      setTypingStatus(true);
    }

    typingTimer?.cancel();
    typingTimer = Timer(const Duration(seconds: 2), () {
      setTypingStatus(false);
      lastTypingUpdate = null;
    });
  }

  Future<bool> isBlockedChat() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return true;
    final currentDoc = await FirebaseFirestore.instance.collection('users').doc(currentUser.uid).get();
    final otherDoc = await FirebaseFirestore.instance.collection('users').doc(widget.otherUserId).get();
    final currentBlocked = List<dynamic>.from(currentDoc.data()?['blockedUsers'] ?? []);
    final otherBlocked = List<dynamic>.from(otherDoc.data()?['blockedUsers'] ?? []);
    return currentBlocked.contains(widget.otherUserId) || otherBlocked.contains(currentUser.uid);
  }

  Future<void> blockUser() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    await FirebaseFirestore.instance.collection('users').doc(currentUser.uid).set({'blockedUsers': FieldValue.arrayUnion([widget.otherUserId]), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    if (mounted) showAppSnack(context, 'User blocked.');
  }

  Future<void> unblockUser() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    await FirebaseFirestore.instance.collection('users').doc(currentUser.uid).set({'blockedUsers': FieldValue.arrayRemove([widget.otherUserId]), 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
    if (mounted) showAppSnack(context, 'User unblocked.');
  }

  Future<void> removeFriend() async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    final requestId = getFriendRequestId(currentUser.uid, widget.otherUserId);
    await FirebaseFirestore.instance.collection('friendRequests').doc(requestId).delete();
    if (mounted) showAppSnack(context, 'Friend removed.');
  }

  Future<void> markMessagesAsSeen(List<QueryDocumentSnapshot<Object?>> docs) async {
    if (markingSeen) return;
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    final canShowReadReceipts = await currentUserShowsReadReceipts();
    if (!canShowReadReceipts) return;
    markingSeen = true;
    try {
      final batch = FirebaseFirestore.instance.batch();
      int updateCount = 0;
      for (final doc in docs) {
        final data = doc.data() as Map<String, dynamic>;
        final senderId = data['senderId'] ?? '';
        final seenBy = List<String>.from(data['seenBy'] ?? []);
        if (senderId != currentUser.uid && !seenBy.contains(currentUser.uid)) {
          batch.update(doc.reference, {'seenBy': FieldValue.arrayUnion([currentUser.uid])});
          updateCount++;
        }
      }
      if (updateCount > 0) await batch.commit();
    } catch (_) {
    } finally {
      markingSeen = false;
    }
  }

  Future<void> cleanupExpiredMessages(List<QueryDocumentSnapshot<Object?>> docs) async {
    if (cleanupRunning) return;
    cleanupRunning = true;
    try {
      final batch = FirebaseFirestore.instance.batch();
      int deleteCount = 0;
      for (final doc in docs) {
        final data = doc.data() as Map<String, dynamic>;
        if (isMessageExpired(data)) {
          batch.delete(doc.reference);
          deleteCount++;
        }
      }
      if (deleteCount > 0) await batch.commit();
    } catch (_) {
    } finally {
      cleanupRunning = false;
    }
  }

  Future<int> getDisappearSeconds() async {
    final chatDoc = await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).get();
    return chatDoc.data()?['disappearSeconds'] ?? 0;
  }

  Future<void> sendMessage() async {
    final text = messageController.text.trim();
    final user = FirebaseAuth.instance.currentUser;
    if (text.isEmpty || user == null) return;
    if (await isBlockedChat()) {
      if (mounted) showAppSnack(context, 'You cannot message this user.');
      return;
    }
    messageController.clear();
    setTypingStatus(false);
    final username = await getCurrentUsername();
    final disappearSeconds = await getDisappearSeconds();
    Timestamp? expiresAt;
    if (disappearSeconds > 0) expiresAt = Timestamp.fromDate(DateTime.now().add(Duration(seconds: disappearSeconds)));
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').add({
      'text': text,
      'textLower': text.toLowerCase(),
      'senderId': user.uid,
      'senderEmail': user.email,
      'senderUsername': username,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'expiresAt': expiresAt,
      'seenBy': [user.uid],
      'deletedFor': [],
      'isEdited': false,
    });
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({
      'lastMessage': text,
      'hiddenFor': [],
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
    scrollToBottom();
  }

  Future<void> openMessageSearch() async {
    final controller = TextEditingController();
    List<QueryDocumentSnapshot<Object?>> results = [];
    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> search() async {
              final q = controller.text.trim().toLowerCase();
              if (q.isEmpty) {
                setDialogState(() => results = []);
                return;
              }
              final snapshot = await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').orderBy('createdAt', descending: true).limit(300).get();
              final currentUid = FirebaseAuth.instance.currentUser?.uid ?? '';
              setDialogState(() {
                results = snapshot.docs.where((doc) {
                  final data = doc.data();
                  final text = (data['text'] ?? '').toString().toLowerCase();
                  final deletedFor = List<dynamic>.from(data['deletedFor'] ?? []);
                  return text.contains(q) && !deletedFor.contains(currentUid) && !isMessageExpired(data);
                }).toList();
              });
            }

            return AlertDialog(
              title: const Text('Search messages'),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: controller, decoration: const InputDecoration(labelText: 'Search text', prefixIcon: Icon(Icons.search)), onSubmitted: (_) => search()),
                    const SizedBox(height: 12),
                    SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: search, icon: const Icon(Icons.search), label: const Text('Search'))),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 260,
                      child: results.isEmpty
                          ? const Center(child: Text('No results yet.', style: TextStyle(color: Colors.white54)))
                          : ListView.builder(
                              itemCount: results.length,
                              itemBuilder: (context, index) {
                                final data = results[index].data() as Map<String, dynamic>;
                                return ListTile(
                                  leading: const Icon(Icons.message_outlined),
                                  title: Text(data['text'] ?? '', maxLines: 2, overflow: TextOverflow.ellipsis),
                                  subtitle: UserNameText(uid: data['senderId'] ?? '', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    controller.dispose();
  }

  Future<void> editMessage(QueryDocumentSnapshot<Object?> messageDoc, String oldText) async {
    final editController = TextEditingController(text: oldText);
    await showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Edit message'),
        content: TextField(controller: editController, decoration: const InputDecoration(labelText: 'Message'), maxLines: null),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final newText = editController.text.trim();
              if (newText.isEmpty) return;
              await messageDoc.reference.update({'text': newText, 'textLower': newText.toLowerCase(), 'isEdited': true, 'editedAt': FieldValue.serverTimestamp(), 'updatedAt': FieldValue.serverTimestamp()});
              await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({'lastMessage': newText, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
              if (mounted) Navigator.pop(dialogContext);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    editController.dispose();
  }

  Future<void> deleteMessageForMe(QueryDocumentSnapshot<Object?> messageDoc) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    await messageDoc.reference.update({'deletedFor': FieldValue.arrayUnion([user.uid]), 'updatedAt': FieldValue.serverTimestamp()});
  }

  Future<void> deleteMessageForEveryone(QueryDocumentSnapshot<Object?> messageDoc) async {
    await messageDoc.reference.delete();
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
  }

  Future<void> showMessageOptions(QueryDocumentSnapshot<Object?> messageDoc, Map<String, dynamic> data) async {
    final currentUser = FirebaseAuth.instance.currentUser;
    if (currentUser == null) return;
    final senderId = data['senderId'] ?? '';
    final fromMe = senderId == currentUser.uid;
    final text = data['text'] ?? '';

    await showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E222A),
      builder: (bottomSheetContext) => SafeArea(
        child: Wrap(
          children: [
            if (fromMe) ListTile(leading: const Icon(Icons.edit), title: const Text('Edit message'), onTap: () { Navigator.pop(bottomSheetContext); editMessage(messageDoc, text); }),
            ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete for me'), onTap: () async { Navigator.pop(bottomSheetContext); await deleteMessageForMe(messageDoc); }),
            if (fromMe) ListTile(leading: const Icon(Icons.delete_forever), title: const Text('Delete for everyone'), onTap: () async { Navigator.pop(bottomSheetContext); await deleteMessageForEveryone(messageDoc); }),
          ],
        ),
      ),
    );
  }

  Future<void> clearChatForMe() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear chat?'),
        content: const Text('This will hide all messages in this chat only for you.'),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Clear'))],
      ),
    );
    if (confirm != true) return;
    final snapshot = await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').limit(500).get();
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in snapshot.docs) {
      batch.update(doc.reference, {'deletedFor': FieldValue.arrayUnion([user.uid])});
    }
    await batch.commit();
  }

  Future<void> updateDisappearSeconds(int seconds) async {
    await FirebaseFirestore.instance.collection('chats').doc(widget.chatId).set({'disappearSeconds': seconds, 'updatedAt': FieldValue.serverTimestamp()}, SetOptions(merge: true));
  }

  Future<void> openDisappearSettings() async {
    final customController = TextEditingController();
    String customUnit = 'minutes';
    String? errorMessage;
    final currentSeconds = await getDisappearSeconds();
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          Future<void> setTimer(int seconds) async {
            await updateDisappearSeconds(seconds);
            if (mounted) {
              Navigator.pop(dialogContext);
              showAppSnack(context, seconds <= 0 ? 'Disappearing messages turned off.' : 'Messages will disappear after ${formatDisappearTime(seconds)}.');
            }
          }

          Future<void> setCustomTimer() async {
            final amount = int.tryParse(customController.text.trim());
            if (amount == null || amount <= 0) {
              setDialogState(() => errorMessage = 'Enter a valid number.');
              return;
            }
            int seconds = amount;
            if (customUnit == 'minutes') seconds = amount * 60;
            if (customUnit == 'hours') seconds = amount * 3600;
            if (customUnit == 'days') seconds = amount * 86400;
            await setTimer(seconds);
          }

          return AlertDialog(
            title: const Text('Disappearing messages'),
            content: SizedBox(
              width: 430,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Current: ${formatDisappearTime(currentSeconds)}', style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 16),
                    ListTile(leading: const Icon(Icons.block), title: const Text('Off'), onTap: () => setTimer(0)),
                    ListTile(leading: const Icon(Icons.timer_outlined), title: const Text('1 minute'), onTap: () => setTimer(60)),
                    ListTile(leading: const Icon(Icons.timer_outlined), title: const Text('1 hour'), onTap: () => setTimer(3600)),
                    ListTile(leading: const Icon(Icons.timer_outlined), title: const Text('1 day'), onTap: () => setTimer(86400)),
                    const Divider(),
                    TextField(controller: customController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount')),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      value: customUnit,
                      decoration: const InputDecoration(labelText: 'Unit'),
                      items: const [
                        DropdownMenuItem(value: 'seconds', child: Text('Seconds')),
                        DropdownMenuItem(value: 'minutes', child: Text('Minutes')),
                        DropdownMenuItem(value: 'hours', child: Text('Hours')),
                        DropdownMenuItem(value: 'days', child: Text('Days')),
                      ],
                      onChanged: (value) { if (value != null) setDialogState(() => customUnit = value); },
                    ),
                    if (errorMessage != null) ...[const SizedBox(height: 12), Text(errorMessage!, style: const TextStyle(color: Colors.redAccent))],
                    const SizedBox(height: 14),
                    SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: setCustomTimer, icon: const Icon(Icons.save), label: const Text('Set custom timer'))),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
    customController.dispose();
  }

  @override
  void dispose() {
    typingTimer?.cancel();
    setTypingStatus(false);
    messageController.dispose();
    scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = FirebaseAuth.instance.currentUser;

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('chats').doc(widget.chatId).snapshots(),
      builder: (context, chatSnapshot) {
        final chatData = chatSnapshot.data?.data();
        final disappearSeconds = chatData?['disappearSeconds'] ?? 0;

        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                UserAvatar(uid: widget.otherUserId, radius: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      UserNameText(uid: widget.otherUserId),
                      TypingStatusText(chatId: widget.chatId, otherUserId: widget.otherUserId),
                    ],
                  ),
                ),
                if (disappearSeconds > 0) Text(formatDisappearTime(disappearSeconds), style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
            backgroundColor: const Color(0xFF111318),
            actions: [
              IconButton(onPressed: openMessageSearch, icon: const Icon(Icons.search), tooltip: 'Search messages'),
              IconButton(onPressed: openDisappearSettings, icon: const Icon(Icons.timer_outlined), tooltip: 'Disappearing messages'),
              IconButton(onPressed: clearChatForMe, icon: const Icon(Icons.cleaning_services_outlined), tooltip: 'Clear chat for me'),
              PopupMenuButton<String>(
                onSelected: (value) async {
                  if (value == 'block') await blockUser();
                  if (value == 'unblock') await unblockUser();
                  if (value == 'remove_friend') await removeFriend();
                },
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'block', child: Text('Block user')),
                  PopupMenuItem(value: 'unblock', child: Text('Unblock user')),
                  PopupMenuItem(value: 'remove_friend', child: Text('Remove friend')),
                ],
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance.collection('chats').doc(widget.chatId).collection('messages').orderBy('createdAt', descending: false).snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.hasError) return const Center(child: Text('Something went wrong loading messages.'));
                    if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
                    final currentUid = currentUser?.uid ?? '';
                    final docs = snapshot.data?.docs ?? [];
                    Future.microtask(() => cleanupExpiredMessages(docs));
                    Future.microtask(() => markMessagesAsSeen(docs));
                    final messages = docs.where((doc) {
                      final data = doc.data() as Map<String, dynamic>;
                      final deletedFor = List<dynamic>.from(data['deletedFor'] ?? []);
                      return !isMessageExpired(data) && !deletedFor.contains(currentUid);
                    }).toList();
                    int lastOwnMessageIndex = -1;
                    for (int i = 0; i < messages.length; i++) {
                      final messageData = messages[i].data() as Map<String, dynamic>;
                      if (messageData['senderId'] == currentUser?.uid) lastOwnMessageIndex = i;
                    }
                    if (messages.isEmpty) return const Center(child: Text('No messages yet. Say hello.', style: TextStyle(color: Colors.white54)));
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (scrollController.hasClients) {
                        scrollController.jumpTo(
                          scrollController.position.maxScrollExtent,
                        );
                      }
                    });

                    return ListView.builder(
                      controller: scrollController,
                      padding: const EdgeInsets.all(16),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final messageDoc = messages[index];
                        final data = messageDoc.data() as Map<String, dynamic>;
                        final text = data['text'] ?? '';
                        final senderId = data['senderId'] ?? '';
                        final expiresAt = data['expiresAt'];
                        final createdAt = data['createdAt'];
                        final seenBy = List<dynamic>.from(data['seenBy'] ?? []);
                        final fromMe = senderId == currentUser?.uid;
                        final isEdited = data['isEdited'] == true;
                        final timeText = createdAt is Timestamp ? formatMessageTime(createdAt) : '';
                        String? expiresText;
                        if (expiresAt is Timestamp) {
                          final remaining = expiresAt.toDate().difference(DateTime.now());
                          if (!remaining.isNegative) {
                            if (remaining.inMinutes < 1) expiresText = 'expires soon';
                            else if (remaining.inHours < 1) expiresText = 'expires in ${remaining.inMinutes}m';
                            else if (remaining.inDays < 1) expiresText = 'expires in ${remaining.inHours}h';
                            else expiresText = 'expires in ${remaining.inDays}d';
                          }
                        }
                        return GestureDetector(
                          onLongPress: () => showMessageOptions(messageDoc, data),
                          onSecondaryTap: () => showMessageOptions(messageDoc, data),
                          child: Align(
                            alignment: fromMe ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 10),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              constraints: const BoxConstraints(maxWidth: 330),
                              decoration: BoxDecoration(
                                color: fromMe ? const Color(0xFF5865F2) : const Color(0xFF2B303A),
                                borderRadius: BorderRadius.only(
                                  topLeft: const Radius.circular(18),
                                  topRight: const Radius.circular(18),
                                  bottomLeft: Radius.circular(fromMe ? 18 : 4),
                                  bottomRight: Radius.circular(fromMe ? 4 : 18),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: fromMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                children: [
                                  UserNameText(uid: senderId, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                                  const SizedBox(height: 4),
                                  Text(text),
                                  const SizedBox(height: 4),
                                  Text(isEdited ? '$timeText · edited' : timeText, style: const TextStyle(color: Colors.white38, fontSize: 10)),
                                  if (fromMe && index == lastOwnMessageIndex) ...[
                                    const SizedBox(height: 4),
                                    ReadReceiptStatus(otherUserId: widget.otherUserId, seenBy: seenBy),
                                  ],
                                  if (expiresText != null) ...[
                                    const SizedBox(height: 4),
                                    Text(expiresText, style: const TextStyle(color: Colors.white38, fontSize: 10)),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                color: const Color(0xFF16191F),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: messageController,
                        onChanged: handleTypingChanged,
                        decoration: InputDecoration(hintText: disappearSeconds > 0 ? 'Message disappears after ${formatDisappearTime(disappearSeconds)}...' : 'Type a message...'),
                        onSubmitted: (_) => sendMessage(),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(onPressed: sendMessage, child: const Icon(Icons.send)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
