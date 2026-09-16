import { SetMetadata } from '@nestjs/common';

export const PERMISSION_KEY = 'ndjo:permission';

export const RequirePermission = (...keys: string[]) =>
  SetMetadata(PERMISSION_KEY, keys);
