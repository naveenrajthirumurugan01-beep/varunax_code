// One-off script: creates (or reuses) the test citizen account for VARUNA X.
//
// Usage (from the project root):
//   npm install firebase-admin --no-save
//   node scripts/create_test_citizen.js
//
// Reads the service account key already checked in at assets/service_account.json.
// Uses the modular firebase-admin API (initializeApp/getAuth/getFirestore)
// rather than the legacy admin.credential.cert() namespace call, since that
// namespace isn't populated the same way across firebase-admin major versions.

const { initializeApp, cert } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore } = require('firebase-admin/firestore');
const path = require('path');

const SERVICE_ACCOUNT_PATH = path.join(__dirname, '..', 'assets', 'service_account.json');

const EMAIL = 'citizen@varunax.com';
const PASSWORD = 'Test@1234';
const DISPLAY_NAME = 'Test Citizen';

const USER_DOC = {
  name: 'Test Citizen',
  email: EMAIL,
  role: 'citizen',
  assignedSiteIds: [],
  registeredZone: 'Palavakkam, Chennai',
  registeredZoneRadius: 5000,
  registeredZoneLatitude: 12.9616562,
  registeredZoneLongitude: 80.256219,
  fcmToken: null,
};

async function main() {
  initializeApp({
    credential: cert(require(SERVICE_ACCOUNT_PATH)),
  });

  const auth = getAuth();
  const db = getFirestore();

  // ---- Task 1: Auth account (create, or reuse if it already exists) ----
  let uid;
  let authAction;
  try {
    const existing = await auth.getUserByEmail(EMAIL);
    uid = existing.uid;
    authAction = 'reused existing';
  } catch (err) {
    if (err.code !== 'auth/user-not-found') throw err;
    const created = await auth.createUser({
      email: EMAIL,
      password: PASSWORD,
      displayName: DISPLAY_NAME,
    });
    uid = created.uid;
    authAction = 'created new';
  }

  // ---- Task 2: Firestore user document (uid as doc id) ----
  await db
    .collection('users')
    .doc(uid)
    .set({ uid, ...USER_DOC }, { merge: true });

  console.log('AUTH_ACTION:', authAction);
  console.log('UID:', uid);
  console.log('FIRESTORE_DOC: users/' + uid + ' written');
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('FAILED:', err);
    process.exit(1);
  });
