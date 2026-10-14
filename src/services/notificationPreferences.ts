export const notificationDefaults = {
  messages: true, visits: true, newSpaces: true, priceDrops: true,
  alerts: false, promos: false,
};
export function resolveNotificationPreferences(value: unknown) {
  const result = { ...notificationDefaults };
  if (value && typeof value === 'object') {
    for (const key of Object.keys(result) as Array<keyof typeof result>) {
      const saved = (value as Record<string, unknown>)[key];
      if (typeof saved === 'boolean') result[key] = saved;
    }
  }
  return result;
}
export function notificationAllowed(value: unknown, type: string): boolean {
  const p = resolveNotificationPreferences(value);
  const t = type.toUpperCase();
  if (t === 'MESSAGE' || t === 'CHAT') return p.messages;
  if (t.startsWith('VISIT')) return p.visits;
  if (t === 'NEW_LISTING') return p.newSpaces;
  if (t === 'PRICE_DROP') return p.priceDrops;
  if (['MATCH', 'SAVED_SEARCH', 'ALERT'].includes(t)) return p.alerts;
  if (['PROMO', 'ANNOUNCEMENT', 'OWNER_INVITE'].includes(t) || t.startsWith('REENGAGE')) return p.promos;
  return true;
}
