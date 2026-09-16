import {
  CanActivate,
  ExecutionContext,
  ForbiddenException,
  Injectable,
} from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { PERMISSION_KEY } from './require-permission.decorator';
import { hasPermission } from './scope';
import { PermissionService } from './permission.service';

@Injectable()
export class AccessGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly permissions: PermissionService,
  ) {}

  async canActivate(context: ExecutionContext): Promise<boolean> {
    const request = context.switchToHttp().getRequest();
    const user = request.user as
      | { sub: string; role: string; establishmentId?: string }
      | undefined;
    if (!user) return true;

    const requested =
      request.query?.establishmentId ||
      request.body?.establishmentId ||
      request.body?.sourceId;

    if (user.role !== 'SUPER_ADMIN' && user.establishmentId) {
      if (requested && requested !== user.establishmentId) {
        throw new ForbiddenException('Accès refusé à cet établissement');
      }
      if (!request.query) request.query = {};
      if (!request.query.establishmentId) {
        request.query.establishmentId = user.establishmentId;
      }
    }

    request.permissions = await this.permissions.keysFor(user.role);
    request.scopedEstablishmentId =
      user.role === 'SUPER_ADMIN'
        ? requested || undefined
        : user.establishmentId;

    const needed = this.reflector.getAllAndOverride<string[]>(PERMISSION_KEY, [
      context.getHandler(),
      context.getClass(),
    ]);
    if (
      needed?.length &&
      !needed.some((key) => hasPermission(request, key))
    ) {
      throw new ForbiddenException('Permission insuffisante');
    }

    return true;
  }
}

export { hasPermission };
