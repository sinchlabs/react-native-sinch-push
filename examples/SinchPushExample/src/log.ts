import {useCallback, useState} from 'react';

const CAPACITY = 200;

export interface ReceivedMessage {
  key: string;
  time: string;
  /** "APNs" or "FCM". */
  channel: string;
  /** Where the SDK handed the message to JS. */
  event: string;
  title?: string;
  body?: string;
  messageId?: string;
}

export interface LogLine {
  key: string;
  time: string;
  text: string;
}

export const clock = () => new Date().toISOString().slice(11, 23);

let counter = 0;

/**
 * Newest-first, in-memory lists (no storage dependency): the received messages
 * and the delivery-event log. Both are lost when the app is killed; a push that
 * only reaches the Notification Service Extension / FCM service never gets to JS.
 */
export function useLogs() {
  const [messages, setMessages] = useState<ReceivedMessage[]>([]);
  const [events, setEvents] = useState<LogLine[]>([]);

  const addMessage = useCallback(
    (m: Omit<ReceivedMessage, 'key' | 'time'>) =>
      setMessages(list => [{...m, key: `m${++counter}`, time: clock()}, ...list].slice(0, CAPACITY)),
    [],
  );
  const addEvent = useCallback(
    (text: string) => setEvents(list => [{key: `e${++counter}`, time: clock(), text}, ...list].slice(0, CAPACITY)),
    [],
  );
  const clear = useCallback(() => {
    setMessages([]);
    setEvents([]);
  }, []);

  return {messages, events, addMessage, addEvent, clear};
}
