import type { LatLng } from "./types.js";

const EARTH_RADIUS_KM = 6371;

export function haversineKm(a: LatLng, b: LatLng): number {
  const toRad = (deg: number) => (deg * Math.PI) / 180;
  const dLat = toRad(b.lat - a.lat);
  const dLng = toRad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(a.lat)) * Math.cos(toRad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(h));
}

// Rough travel time: walking for short hops, city driving otherwise. Shown as an estimate.
export function travelMinutes(km: number): number {
  const kmPerHour = km <= 2 ? 5 : 30;
  return Math.max(1, Math.round((km / kmPerHour) * 60));
}
