import { Injectable } from '@nestjs/common';
import {
  ConnectedSocket,
  MessageBody,
  SubscribeMessage,
  WebSocketGateway,
  WebSocketServer,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { PrismaService } from '../prisma.service';
import { isTrackingToken } from './token';

@WebSocketGateway({ cors: { origin: true }, namespace: '/live' })
@Injectable()
export class TrackingGateway {
  constructor(private readonly prisma: PrismaService) {}

  @WebSocketServer()
  server: Server;

  @SubscribeMessage('track:join')
  async join(
    @ConnectedSocket() client: Socket,
    @MessageBody() body: { token?: string },
  ) {
    const token = body?.token?.trim();
    if (!token || !isTrackingToken(token)) {
      return { ok: false, error: 'NO_TOKEN' };
    }
    const order = await this.prisma.order.findUnique({
      where: { trackingToken: token },
      select: { id: true },
    });
    if (!order) {
      return { ok: false, error: 'WRONG_TOKEN' };
    }
    client.join(`track:${token}`);
    return { ok: true, room: `track:${token}` };
  }

  emitLocation(token: string, payload: Record<string, unknown>) {
    this.server?.to(`track:${token}`).emit('track:location', payload);
  }

  emitStatus(token: string, payload: Record<string, unknown>) {
    this.server?.to(`track:${token}`).emit('track:status', payload);
  }
}
