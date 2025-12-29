package com.xcurenet.pop3reader.mapper;

import org.apache.ibatis.annotations.Mapper;
import org.apache.ibatis.annotations.Param;

@Mapper
public interface ServiceMapper {
	void insert(@Param("accountId") final String accountId, @Param("messageId") final String messageId);
}