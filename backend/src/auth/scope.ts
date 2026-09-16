import { ForbiddenException, NotFoundException } from '@nestjs/common';

export type AuthedRequest = {
  user?: { sub: string; role: string; establishmentId?: string };
  permissions?: string[];
  scopedEstablishmentId?: string;
};

export function hasPermission(
  request: { permissions?: string[] },
  key: string,
) {
  const permissions = request.permissions ?? [];
  return permissions.includes('*') || permissions.includes(key);
}

export function assertSameEstablishment(
  resourceEstablishmentId: string | null | undefined,
  request: AuthedRequest,
  message = 'Accès refusé à cet établissement',
) {
  if (request.user?.role === 'SUPER_ADMIN') return;
  const scoped = request.scopedEstablishmentId;
  if (scoped && resourceEstablishmentId && scoped !== resourceEstablishmentId) {
    throw new ForbiddenException(message);
  }
}

export function mustExist<T>(value: T | null | undefined, message: string): T {
  if (!value) throw new NotFoundException(message);
  return value;
}
