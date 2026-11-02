import { Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { Repository } from 'typeorm';
import { Invoice } from './invoice.entity';

@Injectable()
export class InvoicesService {
  constructor(@InjectRepository(Invoice) private readonly repo: Repository<Invoice>) {}

  async findForOwner(id: string, ownerId: string) {
    const invoice = await this.repo.findOne({ where: { id, ownerId } });
    if (!invoice) throw new NotFoundException();
    return invoice;
  }

  async update(id: string, changes: Partial<Invoice>) {
    await this.repo.update(id, changes);
    return this.repo.findOneBy({ id });
  }
}
