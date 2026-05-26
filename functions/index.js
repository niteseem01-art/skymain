const {onSchedule} = require("firebase-functions/v2/scheduler");
const {onDocumentCreated} = require("firebase-functions/v2/firestore");
const admin = require("firebase-admin");

admin.initializeApp();

exports.cleanupExpiredMessages = onSchedule("every 5 minutes", async () => {
  const now = admin.firestore.Timestamp.now();

  const chatsSnapshot = await admin.firestore().collection("chats").get();

  for (const chatDoc of chatsSnapshot.docs) {
    const expiredMessages = await chatDoc.ref
      .collection("messages")
      .where("expiresAt", "<=", now)
      .limit(100)
      .get();

    if (expiredMessages.empty) {
      continue;
    }

    const batch = admin.firestore().batch();

    expiredMessages.docs.forEach((doc) => {
      batch.delete(doc.ref);
    });

    await batch.commit();
  }
});

exports.notifyOnMessageCreated = onDocumentCreated(
  "chats/{chatId}/messages/{messageId}",
  async (event) => {
    if (!event.data) {
      return;
    }

    const message = event.data.data();
    const chatId = event.params.chatId;

    if (!message || !message.text || !message.senderId) {
      return;
    }

    const chatDoc = await admin.firestore().collection("chats").doc(chatId).get();
    const chat = chatDoc.data();

    if (!chat || !Array.isArray(chat.members)) {
      return;
    }

    const recipients = chat.members.filter((uid) => uid !== message.senderId);

    for (const uid of recipients) {
      const userDoc = await admin.firestore().collection("users").doc(uid).get();
      const user = userDoc.data();

      const blockedUsers = Array.isArray(user?.blockedUsers)
        ? user.blockedUsers
        : [];

      if (blockedUsers.includes(message.senderId)) {
        continue;
      }

      const tokens = Array.isArray(user?.fcmTokens) ? user.fcmTokens : [];

      if (tokens.length === 0) {
        continue;
      }

      await admin.messaging().sendEachForMulticast({
        tokens,
        notification: {
          title: message.senderUsername || "New message",
          body: message.text,
        },
        data: {
          chatId,
          senderId: message.senderId,
        },
      });
    }
  }
);