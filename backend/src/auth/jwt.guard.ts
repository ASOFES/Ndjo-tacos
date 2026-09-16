import {
  CanActivate,
  ExecutionContext,
  Injectable,
  UnauthorizedException,
} from '@nestjs/common';
import { JwtService } from '@nestjs/jwt';

@Injectable()
export class JwtGuard implements CanActivate {
  constructor(private readonly jwt: JwtService) {}

  canActivate(context: ExecutionContext): boolean {
    const request = context.switchToHttp().getRequest();
    const header = request.headers.authorization as string | undefined;
    if (!header?.startsWith('Bearer ')) {
      throw new UnauthorizedException('Session requise');
    }
    const token = header.slice(7).trim();
    if (!token) {
      throw new UnauthorizedException('Session requise');
    }
    try {
      request.user = this.jwt.verify(token, {
        ignoreExpiration: process.env.NODE_ENV !== 'production',
      });
      return true;
    } catch {
      throw new UnauthorizedException('Session expirée');
    }
  }
}
