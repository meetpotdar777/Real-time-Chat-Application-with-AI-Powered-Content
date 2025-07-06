# chat_backend.py
# This script sets up a Flask web server with SocketIO for real-time chat
# and integrates with the Gemini API for content moderation.
# It also uses Firestore to store chat messages.

# IMPORTANT: Monkey-patching must happen as early as possible!
# This makes standard Python I/O non-blocking, which is crucial for real-time servers.
from gevent import monkey # Import monkey from gevent
monkey.patch_all() # Perform monkey-patching for non-blocking I/O

from flask import Flask, jsonify, request
from flask_socketio import SocketIO, emit, join_room, leave_room
from flask_cors import CORS
import os
import json
import asyncio # Keep asyncio for the to_thread calls
from google.cloud import firestore
# firebase_admin is not strictly needed if only using google.cloud.firestore.Client()
# from firebase_admin import credentials, initialize_app
import google.generativeai as genai
import gevent # Import gevent for spawning greenlets
import time # Import time for potential small delays

# Initialize Flask app
app = Flask(__name__)

# Enable CORS for all origins. This is crucial for local development where
# frontend and backend run on different ports. In production, restrict origins.
CORS(app, resources={r"/*": {"origins": "*"}})

# Initialize SocketIO
# Set async_mode to 'gevent' and ensure gevent.monkey_patch() is called at the top.
socketio = SocketIO(app, cors_allowed_origins="*", async_mode='gevent') # <-- async_mode set to 'gevent'

# --- Firebase Firestore Initialization ---
try:
    # In a deployed environment (like Google Cloud Run), default credentials are
    # automatically provided based on the service account associated with the deployment.
    # For local development, GOOGLE_APPLICATION_CREDENTIALS environment variable is needed.
    db = firestore.Client()
    print("Firestore client initialized.")
except Exception as e:
    print(f"Error initializing Firestore client: {e}")
    print("Ensure GOOGLE_APPLICATION_CREDENTIALS is set for local dev, or running in GCP.")
    db = None # Set db to None if initialization fails

# --- Gemini API Initialization ---
try:
    # In a deployed environment, the API key should be managed securely (e.g., Secret Manager).
    # For Canvas, the API key is injected if the variable is empty.
    # For local development, set GEMINI_API_KEY environment variable.
    api_key = os.environ.get("GEMINI_API_KEY", "") # Canvas will inject if empty. For local, replace with your key or set env var.
    if not api_key:
        print("GEMINI_API_KEY environment variable not found. Relying on Canvas injection or default.")
    genai.configure(api_key=api_key)
    model = genai.GenerativeModel('gemini-2.0-flash')
    print("Gemini API initialized successfully.")
except Exception as e:
    print(f"Error initializing Gemini API: {e}")
    model = None # Set model to None if initialization fails

# --- Chat Room Management ---
users_in_rooms = {}

# --- AI Moderation Function ---
async def moderate_message(text):
    """
    Uses the Gemini API to assess if the message content is safe.
    Returns a moderation status and a reason if unsafe.
    """
    if not model:
        print("Gemini model not initialized. Skipping moderation.")
        return {"status": "skipped", "reason": "AI unavailable"}

    try:
        response_schema = {
            "type": "OBJECT",
            "properties": {
                "is_safe": {"type": "BOOLEAN"},
                "reason": {"type": "STRING", "description": "Reason if not safe, or 'N/A' if safe."}
            },
            "required": ["is_safe", "reason"]
        }

        prompt = f"Is the following chat message safe and appropriate for a general audience? Respond with a JSON object containing 'is_safe' (boolean) and 'reason' (string, 'N/A' if safe). Message: '{text}'"

        # Use asyncio.to_thread for potentially blocking calls if not fully async
        response = await asyncio.to_thread(
            lambda: model.generate_content(
                prompt,
                generation_config={
                    "response_mime_type": "application/json",
                    "response_schema": response_schema
                }
            )
        )

        response_text = response.candidates[0].content.parts[0].text
        moderation_result = json.loads(response_text)

        if moderation_result.get("is_safe"):
            return {"status": "safe", "reason": "N/A"}
        else:
            return {"status": "unsafe", "reason": moderation_result.get("reason", "Content flagged by AI.")}

    except Exception as e:
        print(f"Error during AI moderation: {e}")
        return {"status": "error", "reason": f"AI moderation failed: {e}"}

# --- SocketIO Event Handlers ---

# Event handlers should be regular 'def' functions.
# If they need to call an async function, use gevent.spawn() and then .get()
# to wait for its result in a non-blocking way.

@socketio.on('connect')
def handle_connect():
    """Handles new client connections."""
    print(f"Client connected: {request.sid}")
    emit('status', {'message': 'Connected to chat server'}, room=request.sid)

@socketio.on('disconnect')
def handle_disconnect():
    """Handles client disconnections."""
    print(f"Client disconnected: {request.sid}")
    for room_id, users in users_in_rooms.items():
        if request.sid in users:
            del users[request.sid]
            emit('user_left', {'userId': request.sid, 'username': 'A user'}, room=room_id, skip_sid=request.sid)
            print(f"User {request.sid} left room {room_id} on disconnect.")
            break

@socketio.on('join_room')
def handle_join_room(data): # <-- Defined as def (synchronous)
    """
    Handles a client joining a specific chat room.
    Data should contain 'room' (str) and 'userId' (str) and 'username' (str).
    """
    room = data.get('room')
    user_id = data.get('userId')
    username = data.get('username')

    if not room or not user_id or not username:
        emit('error', {'message': 'Room, userId, and username are required to join.'})
        return

    join_room(room)
    if room not in users_in_rooms:
        users_in_rooms[room] = {}
    users_in_rooms[room][user_id] = username
    print(f"User {username} ({user_id}) joined room: {room}")

    emit('user_joined', {'userId': user_id, 'username': username}, room=room, skip_sid=request.sid)

    if db:
        try:
            # In a deployed environment, __app_id is automatically provided.
            # For local dev, ensure it's set as an env var or use a default.
            app_id = os.environ.get("__app_id", "default-app-id")
            messages_ref = db.collection(f'artifacts/{app_id}/public/data/chat_messages').where('room', '==', room).order_by('timestamp').limit(20)
            # Spawn the blocking Firestore stream operation as a greenlet
            # and then .get() its result.
            docs = gevent.spawn(lambda: list(messages_ref.stream())).get() # Convert generator to list immediately
            history = []
            for doc in docs:
                msg_data = doc.to_dict()
                history.append({
                    'userId': msg_data.get('userId'),
                    'username': msg_data.get('username'),
                    'message': msg_data.get('message'),
                    'timestamp': msg_data.get('timestamp').isoformat() if msg_data.get('timestamp') else None,
                    'moderation_status': msg_data.get('moderation_status', 'N/A'),
                    'moderation_reason': msg_data.get('moderation_reason', 'N/A')
                })
            emit('chat_history', {'messages': history}, room=request.sid)
            print(f"Sent chat history to {username} in room {room}")
        except Exception as e:
            print(f"Error fetching chat history for room {room}: {e}")
            emit('error', {'message': f'Failed to load chat history: {e}'}, room=request.sid)
    else:
        emit('error', {'message': 'Firestore not available, cannot load history.'}, room=request.sid)


@socketio.on('leave_room')
def handle_leave_room(data):
    """
    Handles a client leaving a specific chat room.
    Data should contain 'room' (str) and 'userId' (str).
    """
    room = data.get('room')
    user_id = data.get('userId')

    if not room or not user_id:
        emit('error', {'message': 'Room and userId are required to leave.'})
        return

    leave_room(room)
    if room in users_in_rooms and user_id in users_in_rooms[room]:
        username = users_in_rooms[room].pop(user_id)
        print(f"User {username} ({user_id}) left room: {room}")
        emit('user_left', {'userId': user_id, 'username': username}, room=room)
    else:
        print(f"User {user_id} tried to leave room {room} but was not found.")


@socketio.on('send_message')
def handle_message(data): # <-- Defined as def (synchronous)
    """
    Handles incoming chat messages, moderates them, stores in Firestore, and broadcasts.
    Data should contain 'room' (str), 'userId' (str), 'username' (str), and 'message' (str).
    """
    room = data.get('room')
    user_id = data.get('userId')
    username = data.get('username')
    message_text = data.get('message')
    timestamp = firestore.SERVER_TIMESTAMP

    if not room or not user_id or not username or not message_text:
        emit('error', {'message': 'Room, userId, username, and message are required.'})
        return

    print(f"Received message from {username} in room {room}: {message_text}")

    # Spawn the async moderate_message function as a greenlet and wait for its result
    moderation_result = gevent.spawn(moderate_message, message_text).get()
    moderation_status = moderation_result['status']
    moderation_reason = moderation_result['reason']

    message_to_save = {
        'room': room,
        'userId': user_id,
        'username': username,
        'message': message_text,
        'timestamp': timestamp,
        'moderation_status': moderation_status,
        'moderation_reason': moderation_reason
    }

    if db:
        try:
            app_id = os.environ.get("__app_id", "default-app-id")
            # Spawn the blocking Firestore add operation as a greenlet
            doc_ref = gevent.spawn(db.collection(f'artifacts/{app_id}/public/data/chat_messages').add, message_to_save).get()
            print(f"Message saved to Firestore: {doc_ref.id}") # doc_ref.id instead of doc_ref[1].id
        except Exception as e:
            print(f"Error saving message to Firestore: {e}")
            emit('error', {'message': f'Failed to save message: {e}'}, room=request.sid)

    broadcast_message = {
        'userId': user_id,
        'username': username,
        'message': message_text,
        'timestamp': str(timestamp) if isinstance(timestamp, firestore.SERVER_TIMESTAMP) else timestamp.isoformat(),
        'moderation_status': moderation_status,
        'moderation_reason': moderation_reason
    }

    emit('receive_message', broadcast_message, room=room)
    print(f"Message broadcasted to room {room} with status: {moderation_status}")

# --- Flask Routes (for basic health check if needed) ---
@app.route('/')
def index():
    return "Python Chat Backend Running!"

@app.route('/health')
def health_check():
    return jsonify({"status": "ok", "message": "Backend is healthy"})

if __name__ == '__main__':
    print("Starting Flask SocketIO server with Gevent on http://0.0.0.0:5000")
    # For deployment, Gunicorn or an equivalent WSGI server would be used.
    # For local development, socketio.run() is sufficient.
    socketio.run(app, host='0.0.0.0', port=5000, debug=True)
