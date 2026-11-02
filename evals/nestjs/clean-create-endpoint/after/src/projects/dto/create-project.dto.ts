import { IsOptional, IsString, Length, MaxLength } from 'class-validator';

export class CreateProjectDto {
  @IsString()
  @Length(1, 80)
  name!: string;

  @IsOptional()
  @IsString()
  @MaxLength(500)
  description?: string;
}
