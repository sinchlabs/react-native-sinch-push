import type {
  DeviceToken,
  InAppMessage,
  SinchPushConfig,
  SinchPushMessage,
  Subscription,
} from '@sinch/react-native-sinch-push';
import SinchPush from '@sinch/react-native-sinch-push';
import CryptoJS from 'crypto-js';
import React, {useCallback, useEffect, useMemo, useRef, useState} from 'react';
import {
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';

type Env = 'eu1' | 'us1' | 'staging' | 'custom';

type EventRow =
  | {kind: 'token'; at: number; token: DeviceToken}
  | {kind: 'push'; at: number; message: SinchPushMessage}
  | {kind: 'inApp'; at: number; message: InAppMessage}
  | {kind: 'info'; at: number; text: string};

const MAX_LOG_ROWS = 50;
const DEV_SIGN_SECRET = 'e2';

function hmacSha512Hex(message: string, secret: string): string {
  return CryptoJS.HmacSHA512(message, secret).toString(CryptoJS.enc.Hex);
}

function inAppSummary(msg: InAppMessage): string {
  switch (msg.kind) {
    case 'text':
      return `text: ${msg.text}`;
    case 'media':
      return `media: ${msg.url}`;
    case 'location':
      return `location: ${msg.latitude},${msg.longitude}`;
    case 'choice':
      return `choice: ${msg.text} (${msg.choices.length} options)`;
    case 'card':
      return `card: ${msg.title}`;
    case 'carousel':
      return `carousel: ${msg.cards.length} cards`;
  }
}

export function DemoScreen() {
  const [projectID, setProjectID] = useState(
    '490b5866-4b87-45d9-96f6-7ea31fc1b9b2',
  );
  const [clientID, setClientID] = useState('01HDMA7S9F1W5A8ZMW1M2VQBYA');
  const [configID, setConfigID] = useState(
    Platform.OS == 'ios'
      ? '01M0CPNH8634XTZ1GK3NT2E3CR'
      : '01M0D1PDXZFF1B3TBS77R0558Q',
  );
  const [env, setEnv] = useState<Env>('eu1');
  const [customPush, setCustomPush] = useState('');
  const [customChat, setCustomChat] = useState('');
  const [userID, setUserID] = useState(
    `user-${Math.floor(Math.random() * 1e6)}`,
  );

  const [initialized, setInitialized] = useState(false);
  const [deviceToken, setDeviceToken] = useState<DeviceToken | null>(null);
  const [identity, setIdentity] = useState<string | null>(null);
  const [log, setLog] = useState<EventRow[]>([]);

  const subsRef = useRef<{
    token?: Subscription;
    push?: Subscription;
    inApp?: Subscription;
  }>({});

  const pushLog = useCallback((row: EventRow) => {
    setLog(prev => [row, ...prev].slice(0, MAX_LOG_ROWS));
  }, []);

  const info = useCallback(
    (text: string) => pushLog({kind: 'info', at: Date.now(), text}),
    [pushLog],
  );

  useEffect(() => {
    return () => {
      subsRef.current.token?.remove();
      subsRef.current.push?.remove();
      subsRef.current.inApp?.remove();
    };
  }, []);

  const handleInitialize = useCallback(async () => {
    try {
      const config: SinchPushConfig = {
        projectID,
        clientID,
        configID,
        env: env === 'staging' ? 'custom' : env,
        enableLogging: __DEV__,
      };
      if (env === 'staging') {
        config.customPushApiUrl =
          'https://grpc-web.sinch-push.staging.sinch.com';
        config.customChatApiUrl =
          'https://grpc-web.sinch-chat.unauth.staging.sinch.com';
      } else if (env === 'custom') {
        config.customPushApiUrl = customPush;
        config.customChatApiUrl = customChat;
      }
      await SinchPush.initialize(config);
      setInitialized(true);
      info(`initialized (env=${env})`);

      subsRef.current.token?.remove();
      subsRef.current.push?.remove();
      subsRef.current.inApp?.remove();

      subsRef.current.token = SinchPush.onTokenReceiveHandler(t => {
        setDeviceToken(t);
        pushLog({kind: 'token', at: Date.now(), token: t});
      });
      subsRef.current.push = SinchPush.onPushReceiveHandler(m => {
        pushLog({kind: 'push', at: Date.now(), message: m});
      });
      subsRef.current.inApp = SinchPush.onInAppMessageHandler(m => {
        pushLog({kind: 'inApp', at: Date.now(), message: m});
      });

      try {
        const t = await SinchPush.getDeviceToken();
        if (t) {
          setDeviceToken(t);
          info(`captured ${t.type} token via getDeviceToken()`);
        } else {
          info('no device token yet (push service may not be configured)');
        }
      } catch (e) {
        info(`getDeviceToken failed: ${String(e)}`);
      }
    } catch (e) {
      info(`initialize failed: ${String(e)}`);
    }
  }, [
    projectID,
    clientID,
    configID,
    env,
    customPush,
    customChat,
    info,
    pushLog,
  ]);

  const handleSetIdentity = useCallback(async () => {
    if (!initialized) {
      info('initialize first');
      return;
    }
    try {
      const signedUserID = hmacSha512Hex(userID, DEV_SIGN_SECRET);
      await SinchPush.setIdentity({userID, signedUserID});
      setIdentity(userID);
      info(`setIdentity: ${userID}`);
    } catch (e) {
      info(`setIdentity failed: ${String(e)}`);
    }
  }, [initialized, userID, info]);

  const handleRemoveIdentity = useCallback(async () => {
    if (!initialized) {
      info('initialize first');
      return;
    }
    try {
      const signedUserID = hmacSha512Hex(userID, DEV_SIGN_SECRET);
      await SinchPush.removeIdentity({userID, signedUserID});
      setIdentity(null);
      info('removeIdentity ok');
    } catch (e) {
      info(`removeIdentity failed: ${String(e)}`);
    }
  }, [initialized, userID, info]);

  const envs = useMemo<Env[]>(() => ['eu1', 'us1', 'staging', 'custom'], []);

  return (
    <ScrollView
      style={styles.scroll}
      contentContainerStyle={styles.container}
      keyboardShouldPersistTaps="handled">
      <Text style={styles.title}>@sinch/react-native-sinch-push</Text>
      <Text style={styles.subtitle}>
        Platform: {Platform.OS} {`·`} Architecture:{' '}
        {(global as unknown as {__turboModuleProxy?: unknown})
          .__turboModuleProxy
          ? 'new (TurboModule)'
          : 'old (bridge)'}
      </Text>

      <View style={styles.statusBox}>
        <Text style={styles.statusLine}>
          initialized: {initialized ? 'yes' : 'no'}
        </Text>
        <Text style={styles.statusLine}>
          device token:{' '}
          {deviceToken
            ? `${deviceToken.type} ${deviceToken.token.slice(0, 12)}…`
            : 'none'}
        </Text>
        <Text style={styles.statusLine}>identity: {identity ?? 'none'}</Text>
      </View>

      <Section title="Configuration">
        <Field label="projectID" value={projectID} onChange={setProjectID} />
        <Field label="clientID" value={clientID} onChange={setClientID} />
        <Field label="configID" value={configID} onChange={setConfigID} />
        <Text style={styles.fieldLabel}>env</Text>
        <View style={styles.row}>
          {envs.map(e => (
            <TouchableOpacity
              key={e}
              onPress={() => setEnv(e)}
              style={[styles.chip, env === e && styles.chipActive]}>
              <Text
                style={[styles.chipText, env === e && styles.chipTextActive]}>
                {e}
              </Text>
            </TouchableOpacity>
          ))}
        </View>
        {env === 'custom' && (
          <>
            <Field
              label="customPushApiUrl"
              value={customPush}
              onChange={setCustomPush}
            />
            <Field
              label="customChatApiUrl"
              value={customChat}
              onChange={setCustomChat}
            />
          </>
        )}
      </Section>

      <Section title="Identity (for setIdentity demo)">
        <Field label="userID" value={userID} onChange={setUserID} />
      </Section>

      <View style={styles.btnGroup}>
        <Button title="Initialize" onPress={handleInitialize} primary />
        <Button title="Set Identity" onPress={handleSetIdentity} />
        <Button title="Remove Identity" onPress={handleRemoveIdentity} />
      </View>

      <Section title="Event log">
        {log.length === 0 && (
          <Text style={styles.empty}>no events yet — press Initialize</Text>
        )}
        {log.map((row, idx) => (
          <LogRow key={`${row.at}-${idx}`} row={row} />
        ))}
      </Section>
    </ScrollView>
  );
}

function Section({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <View style={styles.section}>
      <Text style={styles.sectionTitle}>{title}</Text>
      <View style={styles.sectionBody}>{children}</View>
    </View>
  );
}

function Field({
  label,
  value,
  onChange,
}: {
  label: string;
  value: string;
  onChange: (v: string) => void;
}) {
  return (
    <View style={styles.field}>
      <Text style={styles.fieldLabel}>{label}</Text>
      <TextInput
        style={styles.input}
        value={value}
        onChangeText={onChange}
        autoCapitalize="none"
        autoCorrect={false}
      />
    </View>
  );
}

function Button({
  title,
  onPress,
  primary,
}: {
  title: string;
  onPress: () => void;
  primary?: boolean;
}) {
  return (
    <TouchableOpacity
      onPress={onPress}
      style={[styles.button, primary && styles.buttonPrimary]}>
      <Text style={[styles.buttonText, primary && styles.buttonTextPrimary]}>
        {title}
      </Text>
    </TouchableOpacity>
  );
}

function LogRow({row}: {row: EventRow}) {
  const ts = new Date(row.at).toLocaleTimeString();
  if (row.kind === 'info') {
    return (
      <View style={styles.logRow}>
        <Text style={[styles.logKind, styles.logInfo]}>INFO</Text>
        <Text style={styles.logBody}>{row.text}</Text>
        <Text style={styles.logTs}>{ts}</Text>
      </View>
    );
  }
  if (row.kind === 'token') {
    return (
      <View style={styles.logRow}>
        <Text style={[styles.logKind, styles.logToken]}>TOKEN</Text>
        <Text style={styles.logBody}>
          {row.token.type} {row.token.token}
        </Text>
        <Text style={styles.logTs}>{ts}</Text>
      </View>
    );
  }
  if (row.kind === 'push') {
    return (
      <View style={styles.logRow}>
        <Text style={[styles.logKind, styles.logPush]}>PUSH</Text>
        <Text style={styles.logBody}>
          {row.message.title ?? row.message.body ?? '(silent)'}{' '}
          {Object.keys(row.message.data).length > 0
            ? `data=${JSON.stringify(row.message.data)}`
            : ''}
        </Text>
        <Text style={styles.logTs}>{ts}</Text>
      </View>
    );
  }
  return (
    <View style={styles.logRow}>
      <Text style={[styles.logKind, styles.logInApp]}>INAPP</Text>
      <Text style={styles.logBody}>{inAppSummary(row.message)}</Text>
      <Text style={styles.logTs}>{ts}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  scroll: {flex: 1, backgroundColor: '#0f1115'},
  container: {padding: 16, paddingBottom: 64},
  title: {
    color: '#fff',
    fontSize: 22,
    fontWeight: '700',
    marginBottom: 4,
  },
  subtitle: {color: '#9aa3b2', fontSize: 12, marginBottom: 16},
  statusBox: {
    backgroundColor: '#1a1f29',
    borderRadius: 8,
    padding: 12,
    marginBottom: 16,
  },
  statusLine: {color: '#cfd6e4', fontSize: 13, marginBottom: 4},
  section: {
    backgroundColor: '#1a1f29',
    borderRadius: 8,
    padding: 12,
    marginBottom: 16,
  },
  sectionTitle: {
    color: '#fff',
    fontSize: 14,
    fontWeight: '600',
    marginBottom: 8,
  },
  sectionBody: {gap: 4},
  field: {marginBottom: 8},
  fieldLabel: {color: '#9aa3b2', fontSize: 12, marginBottom: 4},
  input: {
    backgroundColor: '#0f1115',
    borderColor: '#2a3142',
    borderWidth: 1,
    borderRadius: 6,
    color: '#fff',
    paddingHorizontal: 10,
    paddingVertical: 8,
    fontSize: 14,
  },
  row: {flexDirection: 'row', gap: 8, marginBottom: 8},
  chip: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 14,
    borderColor: '#2a3142',
    borderWidth: 1,
  },
  chipActive: {backgroundColor: '#3a4356', borderColor: '#5b6680'},
  chipText: {color: '#9aa3b2', fontSize: 12},
  chipTextActive: {color: '#fff'},
  btnGroup: {gap: 8, marginBottom: 16},
  button: {
    backgroundColor: '#1a1f29',
    paddingVertical: 12,
    paddingHorizontal: 16,
    borderRadius: 8,
    alignItems: 'center',
  },
  buttonPrimary: {backgroundColor: '#3a6df0'},
  buttonText: {color: '#cfd6e4', fontSize: 14, fontWeight: '600'},
  buttonTextPrimary: {color: '#fff'},
  empty: {color: '#6b7280', fontStyle: 'italic'},
  logRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 6,
    borderBottomColor: '#2a3142',
    borderBottomWidth: StyleSheet.hairlineWidth,
  },
  logKind: {
    fontSize: 10,
    fontWeight: '700',
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 4,
    marginRight: 8,
    overflow: 'hidden',
  },
  logInfo: {backgroundColor: '#2a3142', color: '#cfd6e4'},
  logToken: {backgroundColor: '#1f3a52', color: '#9ec5ff'},
  logPush: {backgroundColor: '#3a2f1f', color: '#ffd29e'},
  logInApp: {backgroundColor: '#1f3a2a', color: '#9eff9e'},
  logBody: {color: '#cfd6e4', fontSize: 12, flex: 1},
  logTs: {color: '#6b7280', fontSize: 10, marginLeft: 8},
});
