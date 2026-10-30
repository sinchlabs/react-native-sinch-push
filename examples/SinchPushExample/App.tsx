/**
 * Sinch Push example (relay off), styled like the native Sinch iOS DemoApp
 * (see src/ui). The start screen has one card per step:
 *
 *   1. Config   - what src/config.ts holds
 *   2. Identity - setIdentity / removeIdentity for a user id
 *   3. Push     - permission + registerForToken, the device token
 *
 * A status badge opens the log screen (like the DemoApp's push message log):
 *
 *   4. Messages - what onPushReceiveHandler delivered (app in the foreground)
 *   5. Events   - local delivery-event log
 *
 * Pushes that arrive while the app is in the background or killed are reported
 * DELIVERED natively by the SDK (iOS: Notification Service Extension / background
 * wake, Android: the SDK's FirebaseMessagingService); JS is not involved and
 * nothing is logged here for them.
 */
import React, {useCallback, useEffect, useRef, useState} from 'react';
import {
  ActivityIndicator,
  AppState,
  BackHandler,
  PermissionsAndroid,
  Platform,
  SafeAreaView,
  ScrollView,
  Share,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';
import {
  getDeviceToken,
  initialize,
  onPushReceiveHandler,
  onTokenReceiveHandler,
  registerForToken,
  removeIdentity,
  setIdentity,
} from '@sinch/react-native-sinch-push';
import {config} from './src/config';
import {missingConfig, usesBackendSigning} from './src/configCheck';
import {ConfigMissingScreen} from './src/ConfigMissingScreen';
import {loadUserId, saveUserId, signIdentity} from './src/identity';
import {useLogs} from './src/log';
import {Card} from './src/ui/Card';
import {PushLogView} from './src/ui/PushLogView';
import {RoundedButton} from './src/ui/RoundedButton';
import {ScreenHeader} from './src/ui/ScreenHeader';
import {BadgeStatus, StatusBadge} from './src/ui/StatusBadge';
import {
  colors,
  fonts,
  radius,
  screenTitle,
  sectionTitle,
  spacing,
} from './src/ui/theme';

const MESSAGE_ID_KEY = 'sinch.push.message_id';

const describe = (e: unknown) => String((e as Error)?.message ?? e);

export default function App() {
  const missing = missingConfig();
  return missing.length > 0 ? (
    <ConfigMissingScreen missing={missing} />
  ) : (
    <Main />
  );
}

function Main() {
  const {messages, events, addMessage, addEvent, clear} = useLogs();
  const [ready, setReady] = useState(false);
  const [userId, setUserId] = useState('');
  const [identityOn, setIdentityOn] = useState(false);
  const [token, setToken] = useState<{token: string; type: string} | null>(
    null,
  );
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [screen, setScreen] = useState<'start' | 'log'>('start');
  const started = useRef(false);

  const run = useCallback(
    async (what: string, fn: () => Promise<void>) => {
      setBusy(true);
      setError(null);
      try {
        await fn();
        addEvent(`${what} ok`);
      } catch (e) {
        setError(`${what}: ${describe(e)}`);
        addEvent(`${what} failed: ${describe(e)}`);
      } finally {
        setBusy(false);
      }
    },
    [addEvent],
  );

  useEffect(() => {
    const subs = [
      onPushReceiveHandler(m => {
        const messageId =
          m.data?.[MESSAGE_ID_KEY] ?? m.data?.message_id ?? m.data?.id;
        addMessage({
          channel: m.source === 'apns' ? 'APNs' : 'FCM',
          event: 'received (foreground)',
          title: m.title,
          body: m.body,
          messageId,
        });
        addEvent(
          `push received in the foreground${
            messageId ? ` (${messageId})` : ''
          }`,
        );
      }),
      onTokenReceiveHandler(t => {
        setToken(t);
        addEvent(`token received (${t.type})`);
      }),
    ];
    const appState = AppState.addEventListener('change', s =>
      addEvent(`app ${s}`),
    );
    return () => {
      subs.forEach(s => s.remove());
      appState.remove();
    };
  }, [addEvent, addMessage]);

  useEffect(() => {
    if (started.current) {
      return;
    }
    started.current = true;
    run('initialize', async () => {
      setUserId(await loadUserId());
      await initialize({
        projectID: config.projectID,
        clientID: config.clientID,
        configID:
          Platform.OS === 'android'
            ? config.configID.android
            : config.configID.ios,
        env: config.env,
        ...(config.env === 'custom'
          ? {
              customPushApiUrl: config.customPushApiUrl,
              customChatApiUrl: config.customChatApiUrl,
            }
          : {}),
        enableLogging: config.enableLogging,
        // The screen registers for the token itself, after setIdentity.
        autoRegisterForToken: false,
        // Turns on the Notification Service Extension report path.
        ...(Platform.OS === 'ios' ? {ios: {appGroup: config.iosAppGroup}} : {}),
      });
      setReady(true);
    });
  }, [run]);

  // The log screen is pushed on top of the start screen; Android back pops it.
  useEffect(() => {
    if (screen !== 'log') {
      return undefined;
    }
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      setScreen('start');
      return true;
    });
    return () => sub.remove();
  }, [screen]);

  const identify = () =>
    run('setIdentity', async () => {
      const id = userId.trim();
      await saveUserId(id);
      await setIdentity(await signIdentity(id));
      setIdentityOn(true);
    });

  const forget = () =>
    run('removeIdentity', async () => {
      await removeIdentity(await signIdentity(userId.trim()));
      setIdentityOn(false);
    });

  const register = () =>
    run('registerForToken', async () => {
      if (Platform.OS === 'android' && Number(Platform.Version) >= 33) {
        const result = await PermissionsAndroid.request(
          PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS,
        );
        addEvent(`POST_NOTIFICATIONS ${result}`);
      }
      // iOS asks for the notification permission inside registerForToken.
      await registerForToken();
      setToken(await getDeviceToken());
    });

  const configId =
    Platform.OS === 'android' ? config.configID.android : config.configID.ios;
  const noInput = busy || !ready || !userId.trim();
  const badgeStatus: BadgeStatus = error
    ? 'error'
    : busy
    ? 'busy'
    : ready
    ? 'ok'
    : 'idle';

  if (screen === 'log') {
    return (
      <View style={styles.root}>
        <StatusBar barStyle="light-content" backgroundColor={colors.brand} />
        <ScreenHeader
          title="Message log"
          left={{
            title: '\u2039 Back',
            accessibilityLabel: 'Back',
            onPress: () => setScreen('start'),
          }}
          right={{
            title: 'Clear',
            onPress: clear,
            disabled: messages.length === 0 && events.length === 0,
          }}
        />
        <SafeAreaView style={styles.root}>
          <ScrollView contentContainerStyle={styles.logContent}>
            <PushLogView messages={messages} events={events} />
          </ScrollView>
        </SafeAreaView>
      </View>
    );
  }

  return (
    <View style={styles.root}>
      <StatusBar barStyle="light-content" backgroundColor={colors.brand} />
      <ScreenHeader title={`Sinch Push (${Platform.OS})`} />
      <SafeAreaView style={styles.root}>
        <ScrollView
          contentContainerStyle={styles.content}
          keyboardShouldPersistTaps="handled">
          <Text style={styles.title}>Explore Sinch Push</Text>

          {!usesBackendSigning() ? (
            <View style={styles.warning} testID="demo-secret-warning">
              <Text style={styles.warningText}>
                DEMO ONLY: identities are signed on the device with
                demoOnlyIdentitySecret. Never ship the secret in an app; set
                signedUserIdUrl to your backend.
              </Text>
            </View>
          ) : null}
          {error ? (
            <View style={styles.error}>
              <Text selectable style={styles.errorText} testID="last-error">
                {error}
              </Text>
            </View>
          ) : null}
          {busy ? (
            <ActivityIndicator style={styles.spinner} color={colors.brand} />
          ) : null}

          <Card
            style={styles.card}
            backgroundColor={colors.cardCream}
            title="Config"
            description="1. What src/config.ts holds.">
            <Text style={styles.mono}>
              env {config.env}
              {config.env === 'custom' ? ` (${config.customPushApiUrl})` : ''}
            </Text>
            <Text style={styles.mono}>project {config.projectID}</Text>
            <Text style={styles.mono}>client {config.clientID}</Text>
            <Text style={styles.mono}>config {configId}</Text>
            {Platform.OS === 'ios' ? (
              <Text style={styles.mono}>app group {config.iosAppGroup}</Text>
            ) : null}
            <Text style={styles.mono}>
              signing{' '}
              {usesBackendSigning()
                ? 'backend (signedUserIdUrl)'
                : 'DEMO secret on device'}
            </Text>
            <Text style={styles.mono}>
              SDK {ready ? 'initialized' : 'not initialized'}
            </Text>
          </Card>

          <Card
            style={styles.card}
            backgroundColor={colors.cardBlue}
            title="Identity"
            description="2. setIdentity / removeIdentity for a user id.">
            <TextInput
              style={styles.input}
              value={userId}
              onChangeText={setUserId}
              autoCapitalize="none"
              autoCorrect={false}
              placeholder="user id"
              placeholderTextColor={colors.secondary}
              testID="user-id"
            />
            <View style={styles.buttons}>
              <RoundedButton
                title="Set identity"
                onPress={identify}
                disabled={noInput}
                flex
              />
              <View style={styles.gap} />
              <RoundedButton
                title="Remove identity"
                onPress={forget}
                disabled={noInput}
                bordered
                flex
              />
            </View>
            <Text style={styles.note}>
              {identityOn
                ? 'Identity set.'
                : 'No identity set in this session.'}
            </Text>
          </Card>

          <Card
            style={styles.card}
            backgroundColor={colors.cardGreen}
            title="Push token"
            description="3. Notification permission, registerForToken and the device token.">
            <RoundedButton
              title="Request permission & register"
              onPress={register}
              disabled={busy || !ready || !identityOn}
            />
            <Text selectable style={styles.token} testID="push-token">
              {token
                ? `${token.type}: ${token.token}`
                : 'no token yet (set an identity first)'}
            </Text>
            {token ? (
              <RoundedButton
                title="Copy / share token"
                onPress={() => Share.share({message: token.token})}
                bordered
              />
            ) : null}
          </Card>

          <Text style={styles.section}>PUSH LOG</Text>
          <StatusBadge
            label={`SDK ${ready ? 'initialized' : 'not initialized'}`}
            status={badgeStatus}
            detail={`${count(messages.length, 'message')} \u00B7 ${count(
              events.length,
              'event',
            )}`}
            onPress={() => setScreen('log')}
            accessibilityHint="Opens the message log"
            testID="log-badge"
          />
        </ScrollView>
      </SafeAreaView>
    </View>
  );
}

function count(n: number, noun: string): string {
  return `${n} ${noun}${n === 1 ? '' : 's'}`;
}

const styles = StyleSheet.create({
  root: {flex: 1, backgroundColor: colors.background},
  // StartView.swift:351-353
  content: {
    paddingHorizontal: spacing.screen,
    paddingVertical: spacing.screenVertical,
  },
  logContent: {paddingHorizontal: spacing.screen, paddingBottom: 24},
  title: {...screenTitle, marginBottom: spacing.screenVertical},
  section: {...sectionTitle, marginBottom: spacing.card},
  card: {marginBottom: spacing.card},
  mono: {
    fontSize: 12,
    fontFamily: fonts.mono,
    color: colors.text,
    marginVertical: 2,
  },
  token: {
    fontSize: 12,
    fontFamily: fonts.mono,
    color: colors.text,
    marginVertical: 8,
  },
  note: {fontSize: 12, color: colors.secondary, marginTop: 8},
  input: {
    height: 36,
    paddingHorizontal: 12,
    borderRadius: radius.button,
    backgroundColor: colors.background,
    color: colors.text,
    fontFamily: fonts.mono,
    fontSize: 13,
  },
  buttons: {flexDirection: 'row', marginTop: 12},
  gap: {width: 8},
  spinner: {marginBottom: spacing.card},
  warning: {
    backgroundColor: colors.cardCream,
    borderColor: colors.orange,
    borderWidth: 1,
    borderRadius: radius.badge,
    padding: 12,
    marginBottom: spacing.card,
  },
  warningText: {color: '#664D03', fontSize: 12, fontWeight: '600'},
  error: {
    backgroundColor: colors.cardRose,
    borderRadius: radius.badge,
    padding: 12,
    marginBottom: spacing.card,
  },
  errorText: {color: colors.red, fontSize: 12, fontWeight: '500'},
});
