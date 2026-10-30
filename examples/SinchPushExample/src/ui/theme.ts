import {Platform, TextStyle} from 'react-native';

/**
 * Visual language of the native Sinch iOS DemoApp (SinchChatDemo): a light,
 * fixed palette (the DemoApp has no dark colorsets and forces a white
 * background), a teal brand colour and pastel cards.
 */
export const colors = {
  /** StartView.swift:197 UIColor(0, 0.44, 0.44), CardView.swift:41 */
  brand: '#007070',
  onBrand: '#FFFFFF',
  /** StartView.swift:352 Color.white */
  background: '#FFFFFF',
  /** StartView.swift:224 / CardView.swift:21 Color.black */
  text: '#000000',
  /**
   * Close to SwiftUI Color.secondary (light), darkened to keep 12 pt hint text
   * above 4.5:1 on white and on the pastel cards.
   */
  secondary: '#5C5C63',
  /** SocketStateBadge.swift:34 Color(0.95, 0.95, 0.95) */
  badgeBackground: '#F2F2F2',
  /** StartView.swift:229, 273 Color(0.87, 0.95, 1) */
  cardBlue: '#DEF2FF',
  /** StartView.swift:247, 308 Color(1, 0.97, 0.9) */
  cardCream: '#FFF7E6',
  /** StartView.swift:256 Color(0.86, 0.93, 0.88) */
  cardGreen: '#DBEDE0',
  /** StartView.swift:331 Color(1, 0.91, 0.89) */
  cardRose: '#FFE8E3',
  /** SwiftUI system colours used by SocketStateModel.swift:53-57 */
  green: '#34C759',
  blue: '#007AFF',
  orange: '#FF9500',
  red: '#FF3B30',
  gray: '#8E8E93',
  /** List separator */
  separator: 'rgba(60, 60, 67, 0.29)',
};

export const radius = {
  /** CardView.swift:48 */
  card: 14,
  /** SocketStateBadge.swift:35 */
  badge: 8,
  /** RoundedButtonStyle.swift:24 */
  button: 6,
  /** PushMessageLogView.swift:26 */
  pill: 4,
};

export const spacing = {
  /** StartView.swift:351 horizontal padding, CardView.swift:45 padding */
  screen: 16,
  /** StartView.swift:353 vertical padding, :227 title bottom padding */
  screenVertical: 24,
  /** Gap between cards, StartView.swift:243 */
  card: 16,
};

export const fonts = {
  mono: Platform.select({ios: 'Menlo', default: 'monospace'}),
};

/** StartView.swift:224 `Font.system(size: 24).weight(.medium)` */
export const screenTitle: TextStyle = {
  fontSize: 24,
  fontWeight: '500',
  color: colors.text,
};

/** StartView.swift:325 "HELP US IMPROVE" section title. */
export const sectionTitle: TextStyle = {
  fontSize: 14,
  fontWeight: '500',
  color: colors.text,
};
