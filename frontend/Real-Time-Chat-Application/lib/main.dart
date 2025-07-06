// main.dart
// This is the main file for the Flutter web application.
// It creates a real-time chat UI, connects to a Python backend via Socket.IO,
// uses Firebase Auth for anonymous login, and Firestore for message history.

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'dart:convert';
import 'dart:js_interop'; // For __firebase_config and __app_id access in web context

// Global variables provided by the Canvas environment
// These are typically injected by the Canvas runtime.
// For local development, you might need to handle these differently or
// replace their usage with hardcoded values for testing.
@JS('__firebase_config')
external String? get firebaseConfigString;

@JS('__app_id')
external String? get appId;

@JS('__initial_auth_token')
external String? get initialAuthToken;

void main() async {
  WidgetsFlutterBinding.ensureInitialized(); // Ensure Flutter bindings are initialized

  // Initialize Firebase using the config provided by the Canvas environment
  try {
    if (firebaseConfigString != null && firebaseConfigString!.isNotEmpty) {
      final firebaseConfig = jsonDecode(firebaseConfigString!);
      await Firebase.initializeApp(
        options: FirebaseOptions(
          apiKey: firebaseConfig['apiKey'],
          appId: firebaseConfig['appId'],
          messagingSenderId: firebaseConfig['messagingSenderId'],
          projectId: firebaseConfig['projectId'],
          authDomain: firebaseConfig['authDomain'],
          databaseURL: firebaseConfig['databaseURL'],
          storageBucket: firebaseConfig['storageBucket'],
        ),
      );
      print("Firebase initialized successfully from __firebase_config.");
    } else {
      // Fallback for local development when Canvas config is not available.
      // YOU MUST REPLACE THESE WITH YOUR ACTUAL FIREBASE WEB CONFIG VALUES
      // from your Firebase project settings -> Add app -> Web.
      // If you don't do this, Firebase features (Auth, Firestore) will not work locally.
      print("Firebase config not found in __firebase_config. Attempting local initialization with YOUR Firebase options.");
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'YOUR_FIREBASE_API_KEY', // <--- REPLACE THIS
          appId: 'YOUR_FIREBASE_APP_ID', // <--- REPLACE THIS
          messagingSenderId: 'YOUR_FIREBASE_MESSAGING_SENDER_ID', // <--- REPLACE THIS
          projectId: 'YOUR_FIREBASE_PROJECT_ID', // <--- REPLACE THIS
          authDomain: 'YOUR_FIREBASE_AUTH_DOMAIN', // <--- REPLACE THIS
          databaseURL: 'YOUR_FIREBASE_DATABASE_URL', // <--- REPLACE THIS (if applicable)
          storageBucket: 'YOUR_FIREBASE_STORAGE_BUCKET', // <--- REPLACE THIS
        ),
      );
      print("Firebase initialized with YOUR actual Firebase options for local run.");
    }
  } catch (e) {
    print("Error initializing Firebase: $e");
    // Optionally show a user-friendly message about Firebase not being available
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Moderated Chat',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        fontFamily: 'Inter', // Using Inter font
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.blueAccent,
          foregroundColor: Colors.white,
          elevation: 4,
        ),
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          filled: true,
          fillColor: Colors.blue.shade50,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.blueAccent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            elevation: 3,
          ),
        ),
      ),
      home: const ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final List<ChatMessage> _messages = [];
  late IO.Socket _socket;
  User? _currentUser;
  String _currentUserId = 'anonymous'; // Default for unauthenticated
  String _currentUsername = 'Guest';
  bool _isAuthenticated = false;
  bool _isSocketConnected = false;
  final String _chatRoomId = 'general_chat_room'; // Fixed room ID for simplicity
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initializeFirebaseAndAuth();
  }

  // Initialize Firebase Auth and listen for state changes
  void _initializeFirebaseAndAuth() async {
    final FirebaseAuth auth = FirebaseAuth.instance;

    auth.authStateChanges().listen((User? user) async {
      if (user == null) {
        print('User is currently signed out.');
        // Sign in anonymously if no user is logged in
        try {
          if (initialAuthToken != null && initialAuthToken!.isNotEmpty) {
            await auth.signInWithCustomToken(initialAuthToken!);
            print("Signed in with custom token.");
          } else {
            await auth.signInAnonymously();
            print("Signed in anonymously.");
          }
          _currentUser = auth.currentUser;
          _currentUserId = _currentUser?.uid ?? 'anonymous';
          _currentUsername = 'User_${_currentUserId.substring(0, 6)}'; // Shorten for display
          setState(() {
            _isAuthenticated = true;
          });
          _initializeSocket(); // Initialize socket after auth
          _listenToFirestoreMessages(); // Start listening to Firestore
        } catch (e) {
          print("Error signing in: $e");
          setState(() {
            _isAuthenticated = false;
          });
        }
      } else {
        print('User is signed in: ${user.uid}');
        _currentUser = user;
        _currentUserId = user.uid;
        _currentUsername = 'User_${_currentUserId.substring(0, 6)}';
        setState(() {
          _isAuthenticated = true;
        });
        _initializeSocket(); // Initialize socket if already authenticated
        _listenToFirestoreMessages(); // Start listening to Firestore
      }
    });

    // Handle initial auth state if already signed in
    if (auth.currentUser != null) {
      _currentUser = auth.currentUser;
      _currentUserId = _currentUser?.uid ?? 'anonymous';
      _currentUsername = 'User_${_currentUserId.substring(0, 6)}';
      setState(() {
        _isAuthenticated = true;
      });
      _initializeSocket();
      _listenToFirestoreMessages();
    }
  }

  // Initialize Socket.IO connection
  void _initializeSocket() {
    // IMPORTANT: Replace this URL with your deployed Python backend URL (e.g., Cloud Run URL)
    // For local testing, keep it as 'http://127.0.0.1:5000'
    _socket = IO.io('http://127.0.0.1:5000', <String, dynamic>{
      'transports': ['websocket'],
      'autoConnect': false, // Connect manually
    });

    _socket.onConnect((_) {
      print('Socket Connected!');
      setState(() {
        _isSocketConnected = true;
      });
      // Emit join_room event after connecting
      _socket.emit('join_room', {
        'room': _chatRoomId,
        'userId': _currentUserId,
        'username': _currentUsername,
      });
      _scrollToBottom();
    });

    _socket.onDisconnect((_) {
      print('Socket Disconnected!');
      setState(() {
        _isSocketConnected = false;
      });
    });

    _socket.onConnectError((err) => print('Socket Connect Error: $err'));
    _socket.onError((err) => print('Socket Error: $err'));

    // Listen for incoming messages
    _socket.on('receive_message', (data) {
      print('Received message: $data');
      final message = ChatMessage.fromJson(data);
      setState(() {
        _messages.add(message);
      });
      _scrollToBottom();
    });

    // Listen for chat history
    _socket.on('chat_history', (data) {
      print('Received chat history: ${data['messages'].length} messages');
      final List<ChatMessage> history = (data['messages'] as List)
          .map((msgJson) => ChatMessage.fromJson(msgJson))
          .toList();
      setState(() {
        _messages.clear(); // Clear existing messages before adding history
        _messages.addAll(history);
      });
      _scrollToBottom();
    });

    // Listen for user join/leave events (optional for UI)
    _socket.on('user_joined', (data) {
      print('User joined: ${data['username']}');
      // Optionally display a system message
    });
    _socket.on('user_left', (data) {
      print('User left: ${data['username']}');
      // Optionally display a system message
    });

    _socket.on('error', (data) {
      print('Server error: $data');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Server Error: ${data['message']}')),
      );
    });

    _socket.connect(); // Manually connect
  }

  // Listen to Firestore for messages (as a fallback/redundancy for history)
  void _listenToFirestoreMessages() {
    // `appId` is provided by the Canvas environment. For local deployment,
    // ensure your Firebase project is properly configured and the app ID is accessible.
    if (FirebaseFirestore.instance == null || appId == null) {
      print("Firestore or App ID not available for listening. (This is expected if Firebase isn't fully configured locally)");
      return;
    }

    // Collection path for public data as per Canvas Firestore rules
    // This path is designed to work with Firebase's security rules for shared data.
    final String collectionPath = 'artifacts/$appId/public/data/chat_messages';

    FirebaseFirestore.instance
        .collection(collectionPath)
        .where('room', isEqualTo: _chatRoomId)
        .orderBy('timestamp', descending: false)
        .limit(20) // Fetch last 20 messages
        .snapshots()
        .listen((snapshot) {
      // This listener will trigger on initial load and any changes.
      // We primarily rely on Socket.IO for real-time, but this ensures history.
      final List<ChatMessage> fetchedMessages = snapshot.docs.map((doc) {
        final data = doc.data();
        return ChatMessage(
          userId: data['userId'] as String,
          username: data['username'] as String,
          message: data['message'] as String,
          timestamp: (data['timestamp'] as Timestamp).toDate(),
          moderationStatus: data['moderation_status'] as String? ?? 'N/A',
          moderationReason: data['moderation_reason'] as String? ?? 'N/A',
        );
      }).toList();

      // Only update if messages are different to avoid UI flicker
      // and if socket history hasn't already populated it.
      if (_messages.isEmpty || _messages.length != fetchedMessages.length ||
          (_messages.isNotEmpty && fetchedMessages.isNotEmpty &&
              _messages.last.timestamp != fetchedMessages.last.timestamp)) {
        setState(() {
          _messages.clear();
          _messages.addAll(fetchedMessages);
        });
        _scrollToBottom();
      }
    }, onError: (error) {
      print("Error listening to Firestore: $error");
    });
  }

  // Scroll to the bottom of the chat list
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // Send message function
  void _sendMessage() {
    if (_messageController.text.trim().isEmpty) return;
    if (!_isSocketConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Not connected to chat server.')),
      );
      return;
    }

    final messageData = {
      'room': _chatRoomId,
      'userId': _currentUserId,
      'username': _currentUsername,
      'message': _messageController.text.trim(),
    };

    _socket.emit('send_message', messageData);
    _messageController.clear();
  }

  @override
  void dispose() {
    _socket.disconnect();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Moderated Chat'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _isAuthenticated ? 'Logged in as: $_currentUsername' : 'Logging in...',
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  Text(
                    _isSocketConnected ? 'Status: Connected' : 'Status: Disconnected',
                    style: TextStyle(
                      fontSize: 12,
                      color: _isSocketConnected ? Colors.greenAccent : Colors.redAccent,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _messages.isEmpty && !_isSocketConnected
                ? const Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Connecting to chat...'),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16.0),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) {
                      final message = _messages[index];
                      final isMe = message.userId == _currentUserId;
                      return ChatBubble(
                        message: message,
                        isMe: isMe,
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      hintText: 'Type your message...',
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.blueAccent, width: 2),
                      ),
                    ),
                    onSubmitted: (value) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 10),
                FloatingActionButton(
                  onPressed: _sendMessage,
                  backgroundColor: Colors.blueAccent,
                  foregroundColor: Colors.white,
                  elevation: 3,
                  child: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// Model for a chat message
class ChatMessage {
  final String userId;
  final String username;
  final String message;
  final DateTime timestamp;
  final String moderationStatus; // e.g., 'safe', 'unsafe', 'skipped', 'error'
  final String moderationReason; // Reason if unsafe

  ChatMessage({
    required this.userId,
    required this.username,
    required this.message,
    required this.timestamp,
    this.moderationStatus = 'N/A',
    this.moderationReason = 'N/A',
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      userId: json['userId'] as String,
      username: json['username'] as String,
      message: json['message'] as String,
      timestamp: json['timestamp'] is String
          ? DateTime.parse(json['timestamp'])
          : (json['timestamp'] as Timestamp).toDate(),
      moderationStatus: json['moderation_status'] as String? ?? 'N/A',
      moderationReason: json['moderation_reason'] as String? ?? 'N/A',
    );
  }
}

// Custom widget for displaying a chat bubble
class ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final bool isMe;

  const ChatBubble({
    super.key,
    required this.message,
    required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final Color bubbleColor = isMe ? Colors.blueAccent : Colors.grey.shade300;
    final Color textColor = isMe ? Colors.white : Colors.black87;
    final Color moderationColor = message.moderationStatus == 'unsafe' ? Colors.red.shade700 : Colors.green.shade700;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 15),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomLeft: isMe ? Radius.circular(16) : Radius.circular(4),
            bottomRight: isMe ? Radius.circular(4) : Radius.circular(16),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 3,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isMe ? 'You' : message.username,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isMe ? Colors.white70 : Colors.blue.shade800,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message.message,
              style: TextStyle(color: textColor, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${message.timestamp.hour}:${message.timestamp.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(
                    color: isMe ? Colors.white60 : Colors.black54,
                    fontSize: 10,
                  ),
                ),
                if (message.moderationStatus != 'N/A') ...[
                  const SizedBox(width: 8),
                  Icon(
                    message.moderationStatus == 'safe' ? Icons.check_circle : Icons.warning,
                    size: 14,
                    color: moderationColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    message.moderationStatus == 'safe' ? 'Safe' : 'Flagged',
                    style: TextStyle(
                      color: moderationColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            ),
            if (message.moderationStatus == 'unsafe' && message.moderationReason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4.0),
                child: Text(
                  'Reason: ${message.moderationReason}',
                  style: TextStyle(
                    color: Colors.red.shade200,
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
